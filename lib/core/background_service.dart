import 'dart:io';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'package:anyware/core/logger.dart';

final _log = AppLogger('BackgroundService');

/// Manages Android foreground service and cross-platform wakelock to prevent
/// the OS from killing the app during active file transfers.
///
/// All user-visible strings are passed in by the caller so that notifications
/// respect the selected locale.
///
/// Usage:
///   await BackgroundTransferService.instance.init();
///   BackgroundTransferService.instance.onTransferStarted(title: '...', text: '...');
///   BackgroundTransferService.instance.updateProgress(title: '...', text: '...');
///   BackgroundTransferService.instance.onTransferFinished();
class BackgroundTransferService {
  BackgroundTransferService._();

  static final BackgroundTransferService instance =
      BackgroundTransferService._();

  /// Number of currently active transfers. The foreground service and wakelock
  /// are active as long as this is > 0 (or sync is active).
  int _activeCount = 0;

  /// Whether sync watching is active (file watchers running / server listening).
  /// When true the foreground service stays alive even without active transfers.
  bool _syncActive = false;
  int _syncWatchCount = 0;

  bool _initialized = false;

  /// Cached sync notification strings so that `_updateSyncNotification` can
  /// re-use the last provided localised text without requiring `ref`.
  String _syncNotifTitle = 'Sync active';
  String _syncNotifText = '';

  /// Initialise the foreground task configuration (Android only).
  /// Safe to call on all platforms — non-Android is a no-op.
  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    if (!Platform.isAndroid) return;

    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'lifeos_transfer',
        channelName: 'File Transfer',
        channelDescription: 'Shows progress while transferring files',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
        playSound: false,
        enableVibration: false,
        visibility: NotificationVisibility.VISIBILITY_PUBLIC,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        autoRunOnBoot: false,
        autoRunOnMyPackageReplaced: false,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );

    _log.info('Foreground task configured');
  }

  /// Call when a new transfer starts. Starts the foreground service (Android)
  /// and enables wakelock on the first active transfer.
  ///
  /// [title] and [text] are localised notification strings provided by the caller.
  Future<void> onTransferStarted({
    required String title,
    required String text,
  }) async {
    _activeCount++;
    _log.debug('Transfer started (active: $_activeCount)');

    if (_activeCount == 1) {
      // First active transfer — acquire system resources.
      try {
        await WakelockPlus.enable();
        _log.debug('Wakelock enabled');
      } catch (e) {
        _log.warning('Failed to enable wakelock: $e');
      }

      if (Platform.isAndroid) {
        try {
          await FlutterForegroundTask.startService(
            notificationTitle: title,
            notificationText: text,
            callback: _foregroundTaskCallback,
          );
          _log.info('Foreground service started');
        } catch (e) {
          _log.warning('Failed to start foreground service: $e');
        }
      }
    } else if (Platform.isAndroid) {
      // Update notification to show multiple active transfers.
      try {
        await FlutterForegroundTask.updateService(
          notificationTitle: title,
          notificationText: text,
        );
      } catch (e) {
        _log.warning('Failed to update foreground service: $e');
      }
    }
  }

  /// Call when a transfer completes, fails, or is cancelled. Stops the
  /// foreground service and wakelock when no transfers remain
  /// (unless sync watchers are still active).
  Future<void> onTransferFinished() async {
    _activeCount = (_activeCount - 1).clamp(0, 999);
    _log.debug('Transfer finished (active: $_activeCount)');

    if (_activeCount == 0 && !_syncActive) {
      // No more active transfers AND no sync watching — release resources.
      try {
        await WakelockPlus.disable();
        _log.debug('Wakelock disabled');
      } catch (e) {
        _log.warning('Failed to disable wakelock: $e');
      }

      if (Platform.isAndroid) {
        try {
          await FlutterForegroundTask.stopService();
          _log.info('Foreground service stopped');
        } catch (e) {
          _log.warning('Failed to stop foreground service: $e');
        }
      }
    } else if (_activeCount == 0 && _syncActive && Platform.isAndroid) {
      // Transfers done but sync still active — update notification.
      _updateSyncNotification();
    } else if (Platform.isAndroid) {
      // Still have active transfers — caller should call updateProgress next.
    }
  }

  /// Updates the Android notification with current transfer progress.
  ///
  /// [title] and [text] are localised strings provided by the caller.
  Future<void> updateProgress({
    required String title,
    required String text,
  }) async {
    if (!Platform.isAndroid) return;

    try {
      await FlutterForegroundTask.updateService(
        notificationTitle: title,
        notificationText: text,
      );
    } catch (_) {
      // Ignore — notification updates are best-effort.
    }
  }

  // ────────────────────────────────────────────────────────────────────────
  // Sync foreground service — keeps the app alive while watching folders
  // ────────────────────────────────────────────────────────────────────────

  /// Call when a sync watcher starts (job enters watching phase).
  /// Starts the foreground service if not already running.
  ///
  /// [title] and [text] are localised notification strings.
  Future<void> onSyncWatchStarted({
    required String title,
    required String text,
  }) async {
    _syncWatchCount++;
    _syncActive = true;
    _syncNotifTitle = title;
    _syncNotifText = text;
    _log.debug('Sync watch started (watching: $_syncWatchCount)');

    if (_activeCount == 0) {
      // No transfer active — we need to start foreground service for sync.
      try {
        await WakelockPlus.enable();
      } catch (e) {
        _log.warning('Failed to enable wakelock for sync: $e');
      }

      if (Platform.isAndroid) {
        try {
          await FlutterForegroundTask.startService(
            notificationTitle: title,
            notificationText: text,
            callback: _foregroundTaskCallback,
          );
          _log.info('Foreground service started for sync watching');
        } catch (e) {
          _log.warning('Failed to start foreground service for sync: $e');
        }
      }
    } else if (Platform.isAndroid) {
      // Transfer already active — just update notification.
      _updateSyncNotification();
    }
  }

  /// Call when a sync watcher stops.
  /// Stops the foreground service if no more watchers or transfers active.
  Future<void> onSyncWatchStopped() async {
    _syncWatchCount = (_syncWatchCount - 1).clamp(0, 999);
    if (_syncWatchCount == 0) _syncActive = false;
    _log.debug('Sync watch stopped (watching: $_syncWatchCount)');

    if (_syncWatchCount == 0 && _activeCount == 0) {
      // Nothing left — release resources.
      try {
        await WakelockPlus.disable();
      } catch (e) {
        _log.warning('Failed to disable wakelock: $e');
      }

      if (Platform.isAndroid) {
        try {
          await FlutterForegroundTask.stopService();
          _log.info('Foreground service stopped (no sync/transfer)');
        } catch (e) {
          _log.warning('Failed to stop foreground service: $e');
        }
      }
    } else if (Platform.isAndroid) {
      _updateSyncNotification();
    }
  }

  /// Updates the sync notification title/text. Call this when the locale
  /// changes while sync is active so the notification text stays current.
  void updateSyncNotifStrings({
    required String title,
    required String text,
  }) {
    _syncNotifTitle = title;
    _syncNotifText = text;
    if (_syncActive && _activeCount == 0 && Platform.isAndroid) {
      _updateSyncNotification();
    }
  }

  void _updateSyncNotification() {
    if (!Platform.isAndroid) return;
    try {
      if (_activeCount > 0) {
        // Transfer takes priority in notification.
        return;
      }
      FlutterForegroundTask.updateService(
        notificationTitle: _syncNotifTitle,
        notificationText: _syncNotifText,
      );
    } catch (_) {}
  }
}

/// Top-level callback required by flutter_foreground_task.
/// We don't need any periodic work — just the service staying alive.
@pragma('vm:entry-point')
void _foregroundTaskCallback() {
  FlutterForegroundTask.setTaskHandler(_TransferTaskHandler());
}

class _TransferTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    // No-op — the service just needs to stay alive.
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    // No-op — we don't use repeat events.
  }

  @override
  Future<void> onDestroy(DateTime timestamp) async {
    // No-op.
  }
}
