import 'dart:async';
import 'dart:io';

import 'package:anyware/core/constants.dart';
import 'package:anyware/features/discovery/presentation/providers.dart';
import 'package:anyware/features/platform/windows/notification_service.dart';
import 'package:anyware/features/settings/presentation/providers.dart';
import 'package:anyware/features/settings/data/settings_repository.dart';
import 'package:anyware/features/transfer/data/file_sender.dart';
import 'package:anyware/features/clipboard/data/clipboard_service.dart';
import 'package:anyware/features/transfer/data/file_server.dart';
import 'package:anyware/features/transfer/data/transfer_history.dart';
import 'package:anyware/features/transfer/data/transfer_queue.dart';
import 'package:anyware/features/transfer/domain/transfer.dart';
import 'package:anyware/core/logger.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final _log = AppLogger('TransferProviders');

// ---------------------------------------------------------------------------
// FileServer
// ---------------------------------------------------------------------------

/// Provides a managed [FileServer] instance that is fully started.
///
/// The server is started asynchronously (HTTP bind), then returned.
/// It is kept alive so that incoming file transfers are always accepted,
/// even when the Transfers tab is not visible.
final fileServerProvider = FutureProvider.autoDispose<FileServer>((ref) async {
  final device = await ref.watch(localDeviceProvider.future);
  final settingsRepo = ref.watch(settingsRepositoryProvider);

  String downloadPath = '';
  bool overwriteFiles = false;
  try {
    final settings = await settingsRepo.load();
    downloadPath = settings.downloadPath;
    overwriteFiles = settings.overwriteFiles;
  } catch (_) {
    // Will be empty; FileServer creates dirs as needed.
  }

  final server = FileServer(
    localDevice: device,
    downloadPath: downloadPath,
    overwriteFiles: overwriteFiles,
  );

  // Wire clipboard receive events to persistent history.
  server.onClipboardReceived = (Map<String, dynamic> data) {
    final entry = ClipboardEntry(
      text: data['text'] as String? ?? '',
      imagePath: data['imagePath'] as String?,
      senderName: data['sender'] as String? ?? 'Unknown',
      senderDeviceId: data['senderDeviceId'] as String? ?? '',
      timestamp: DateTime.tryParse(data['timestamp'] as String? ?? '') ??
          DateTime.now(),
      type: (data['type'] as String?) == 'image'
          ? ClipboardContentType.image
          : ClipboardContentType.text,
    );
    ref.read(clipboardHistoryProvider.notifier).addEntry(entry);
  };

  try {
    await server.start(AppConstants.defaultPort);
    _log.info('Started on port ${AppConstants.defaultPort}');
  } catch (e) {
    _log.error('Failed to start on port ${AppConstants.defaultPort}: $e', error: e);
  }

  ref.onDispose(() {
    server.dispose();
  });

  // Keep the provider alive so the HTTP server never stops.
  ref.keepAlive();

  return server;
});

// ---------------------------------------------------------------------------
// FileSender
// ---------------------------------------------------------------------------

/// Provides a [FileSender] instance tied to the local device.
///
/// Also reads the current upload speed limit from settings.
final fileSenderProvider = FutureProvider.autoDispose<FileSender>((ref) async {
  final device = await ref.watch(localDeviceProvider.future);
  final settings = ref.watch(settingsProvider);

  final sender = FileSender(localDevice: device)
    ..maxUploadSpeedKBps = settings.maxUploadSpeedKBps;

  ref.onDispose(() {
    sender.dispose();
  });

  ref.keepAlive();

  return sender;
});

// ---------------------------------------------------------------------------
// Transfer Queue
// ---------------------------------------------------------------------------

/// Provides a [TransferQueue] that processes file sends sequentially.
final transferQueueProvider =
    FutureProvider.autoDispose<TransferQueue>((ref) async {
  final sender = await ref.watch(fileSenderProvider.future);

  final queue = TransferQueue(sender: sender);

  ref.onDispose(() {
    queue.dispose();
  });

  ref.keepAlive();
  return queue;
});

// ---------------------------------------------------------------------------
// Incoming requests
// ---------------------------------------------------------------------------

/// A stream of incoming transfer requests received by the [FileServer].
///
/// UI layers can listen to this to show accept/reject dialogs.
final incomingRequestsProvider = StreamProvider.autoDispose<Transfer>((ref) async* {
  final server = await ref.watch(fileServerProvider.future);
  await for (final request in server.incomingRequests) {
    yield request;
  }
});

// ---------------------------------------------------------------------------
// Active transfers
// ---------------------------------------------------------------------------

/// Manages the list of all active and recent transfers (both incoming and
/// outgoing). The UI can read this to display a transfer list with progress.
final activeTransfersProvider =
    StateNotifierProvider.autoDispose<ActiveTransfersNotifier, List<Transfer>>(
  (ref) {
    final historyNotifier = ref.read(transferHistoryProvider.notifier);
    final notifier = ActiveTransfersNotifier(historyNotifier: historyNotifier);

    // Listen to file server progress updates when the server is ready.
    ref.listen<AsyncValue<FileServer>>(fileServerProvider, (_, next) {
      next.whenData((server) {
        notifier.listenToServer(server);
      });
    }, fireImmediately: true);

    // Listen to file sender progress updates when the sender is ready.
    ref.listen<AsyncValue<FileSender>>(fileSenderProvider, (_, next) {
      next.whenData((sender) {
        notifier.listenToSender(sender);
      });
    }, fireImmediately: true);

    return notifier;
  },
);

/// [StateNotifier] that merges progress updates from both the [FileServer]
/// (incoming) and [FileSender] (outgoing) into a single ordered list.
class ActiveTransfersNotifier extends StateNotifier<List<Transfer>> {
  ActiveTransfersNotifier({this.historyNotifier}) : super([]);

  final TransferHistoryNotifier? historyNotifier;
  StreamSubscription<Transfer>? _serverSub;
  StreamSubscription<Transfer>? _senderSub;

  /// Start listening to server progress updates.
  void listenToServer(FileServer server) {
    _serverSub?.cancel();
    _serverSub = server.progressUpdates.listen(_onTransferUpdate);
  }

  /// Start listening to sender progress updates.
  void listenToSender(FileSender sender) {
    _senderSub?.cancel();
    _senderSub = sender.progressUpdates.listen(_onTransferUpdate);

    // Handle ID changes: when the server assigns a real transferId,
    // replace the placeholder entry so we don't get duplicates.
    sender.onTransferIdChanged = (String oldId, Transfer updated) {
      final index = state.indexWhere((t) => t.id == oldId);
      if (index >= 0) {
        state = [
          for (int i = 0; i < state.length; i++)
            if (i == index) updated else state[i],
        ];
      }
    };
  }

  /// Adds a new transfer or updates an existing one (matched by id).
  void addOrUpdate(Transfer transfer) {
    _onTransferUpdate(transfer);
  }

  /// Removes a transfer by its id.
  void remove(String transferId) {
    state = [
      for (final t in state)
        if (t.id != transferId) t,
    ];
  }

  /// Clears all finished (completed / failed / cancelled / rejected) transfers.
  void clearFinished() {
    state = [
      for (final t in state)
        if (t.isActive) t,
    ];
  }

  @override
  void dispose() {
    _serverSub?.cancel();
    _senderSub?.cancel();
    super.dispose();
  }

  // Private ---------------------------------------------------------------

  void _onTransferUpdate(Transfer transfer) {
    final index = state.indexWhere((t) => t.id == transfer.id);

    // Determine previous status for notification triggers.
    TransferStatus? prevStatus;
    if (index >= 0) {
      prevStatus = state[index].status;
    }

    if (index >= 0) {
      state = [
        for (int i = 0; i < state.length; i++)
          if (i == index) transfer else state[i],
      ];
    } else {
      state = [...state, transfer];
    }

    // Record completed/failed transfers to persistent history.
    if ((transfer.status == TransferStatus.completed ||
            transfer.status == TransferStatus.failed) &&
        prevStatus != transfer.status) {
      historyNotifier?.recordTransfer(transfer);
    }

    // Fire Windows notifications for incoming transfers only.
    if (Platform.isWindows) {
      _fireNotification(transfer, prevStatus);
    }
  }

  void _fireNotification(Transfer transfer, TransferStatus? prevStatus) {
    final notif = WindowsNotificationService.instance;

    // New incoming transfer starts transferring.
    if (transfer.status == TransferStatus.transferring &&
        prevStatus != TransferStatus.transferring) {
      final sender = transfer.senderDevice.name;
      notif.notifyTransferStarted(transfer.fileName, sender);
    }

    // Transfer completed.
    if (transfer.status == TransferStatus.completed &&
        prevStatus != TransferStatus.completed) {
      notif.notifyTransferCompleted(transfer.fileName);
    }

    // Transfer failed.
    if (transfer.status == TransferStatus.failed &&
        prevStatus != TransferStatus.failed) {
      notif.notifyTransferFailed(transfer.fileName);
    }
  }
}
