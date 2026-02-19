import 'dart:async';
import 'dart:io';

import 'package:anyware/core/logger.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:watcher/watcher.dart';

import 'package:anyware/features/discovery/domain/device.dart';
import 'package:anyware/features/sync/domain/sync_state.dart';

import 'package:anyware/features/sync/data/sync_sender.dart';

final syncServiceProvider = StateNotifierProvider<SyncService, SyncState>((ref) {
  return SyncService(ref);
});

class SyncService extends StateNotifier<SyncState> {
  SyncService(this.ref) : super(const SyncState());

  static final _log = AppLogger('SyncService');

  final Ref ref;

  StreamSubscription<WatchEvent>? _watcherSubscription;
  Timer? _debounceTimer;
  final Set<String> _pendingFiles = {};

  /// Maximum retry attempts for failed sync files.
  static const int _maxRetries = 2;

  /// Starts watching the given [directory] and syncing changes to [targetDevice].
  Future<void> startSync(String directory, Device targetDevice) async {
    if (state.isSyncing) return;

    final dir = Directory(directory);
    if (!dir.existsSync()) {
      throw FileSystemException('Directory does not exist', directory);
    }

    state = state.copyWith(
      isSyncing: true,
      sourceDirectory: directory,
      targetDevice: targetDevice,
      lastSyncTime: DateTime.now(),
      status: 'Initial scan...',
      failedFiles: [],
      failedCount: 0,
      syncedCount: 0,
    );

    // Initial sync: Scan existing files
    try {
      final entities = dir.listSync(recursive: true);
      for (final entity in entities) {
        if (entity is File) {
          _pendingFiles.add(entity.path);
        }
      }
      _log.info('Found ${_pendingFiles.length} existing files.');

      _debounceTimer?.cancel();
      _debounceTimer = Timer(const Duration(milliseconds: 500), _processPendingFiles);
    } catch (e) {
      _log.error('Initial scan failed: $e', error: e);
      state = state.copyWith(status: 'Initial scan failed: $e');
    }

    try {
      final watcher = DirectoryWatcher(directory);
      _watcherSubscription = watcher.events.listen((event) {
        _handleFileEvent(event);
      }, onError: (e) {
        _log.error('Watcher error: $e', error: e);
        state = state.copyWith(status: 'Error monitoring directory');
      });
      _log.info('Started watching $directory');
    } catch (e) {
       _log.error('Failed to start watcher: $e', error: e);
       stopSync();
    }
  }

  void stopSync() {
    _watcherSubscription?.cancel();
    _watcherSubscription = null;
    _debounceTimer?.cancel();
    _pendingFiles.clear();

    state = state.copyWith(
      isSyncing: false,
      status: 'Sync stopped',
    );
    _log.info('Stopped sync');
  }

  void _handleFileEvent(WatchEvent event) {
    if (event.type == ChangeType.REMOVE) {
      _handleDeleteEvent(event.path);
      return;
    }

    if (FileSystemEntity.isDirectorySync(event.path)) return;

    _log.debug('File changed: ${event.path} (${event.type})');

    _pendingFiles.add(event.path);
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(seconds: 2), _processPendingFiles);

    state = state.copyWith(status: 'Change detected...');
  }

  /// Handles deletion events — sends delete request to the target device.
  Future<void> _handleDeleteEvent(String path) async {
    if (state.targetDevice == null || state.sourceDirectory == null) return;

    _log.info('File deleted: $path');

    final sender = ref.read(syncSenderProvider);
    final success = await sender.sendDelete(
      state.targetDevice!,
      path,
      state.sourceDirectory!,
    );

    if (success) {
      _log.info('Synced deletion of $path');
    } else {
      _log.warning('Failed to sync deletion of $path');
    }
  }

  Future<void> _processPendingFiles() async {
    if (_pendingFiles.isEmpty || state.targetDevice == null) return;

    final filesToSync = List<String>.from(_pendingFiles);
    _pendingFiles.clear();

    state = state.copyWith(
      status: 'Syncing ${filesToSync.length} files...',
      failedFiles: [],
      failedCount: 0,
      syncedCount: 0,
    );

    final sender = ref.read(syncSenderProvider);
    int successCount = 0;
    final failures = <SyncError>[];

    for (final filePath in filesToSync) {
      if (!state.isSyncing) break;
      if (state.sourceDirectory == null) continue;

      // Try with retries.
      bool success = false;
      String? lastError;

      for (int attempt = 1; attempt <= _maxRetries + 1; attempt++) {
        success = await sender.sendFile(
          state.targetDevice!,
          filePath,
          state.sourceDirectory!,
        );

        if (success) break;

        lastError = 'Failed after attempt $attempt';
        if (attempt <= _maxRetries) {
          await Future<void>.delayed(Duration(seconds: attempt));
        }
      }

      if (success) {
        successCount++;
      } else {
        final relativePath = state.sourceDirectory != null
            ? p.relative(filePath, from: state.sourceDirectory!)
            : filePath;
        failures.add(SyncError(
          filePath: relativePath,
          error: lastError ?? 'Unknown error',
          timestamp: DateTime.now(),
        ));
      }

      // Update progress during sync.
      final processed = successCount + failures.length;
      state = state.copyWith(
        status: 'Syncing... ($processed/${filesToSync.length})',
        syncedCount: successCount,
        failedCount: failures.length,
      );
    }

    final failedCount = failures.length;
    _log.info(
      'Synced $successCount/${filesToSync.length} files '
      '($failedCount failed) to ${state.targetDevice?.name}',
    );

    String statusMsg;
    if (failedCount == 0) {
      statusMsg = 'Synced $successCount files successfully';
    } else {
      statusMsg = 'Synced $successCount files, $failedCount failed';
    }

    state = state.copyWith(
      lastSyncTime: DateTime.now(),
      status: statusMsg,
      syncedCount: successCount,
      failedCount: failedCount,
      failedFiles: failures,
    );
  }
}
