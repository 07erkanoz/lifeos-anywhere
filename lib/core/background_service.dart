import 'dart:io';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'package:anyware/core/logger.dart';

final _log = AppLogger('BackgroundService');

/// Manages an **always-on** Android foreground service and cross-platform
/// wakelock so that the OS never kills the app while it is open.
///
/// The service is started once at app launch via [startPersistentService] and
/// is **never** stopped. Transfer / sync activity only *updates* the
/// notification text; when idle the notification shows a "Ready" message.
///
/// Notification priority: Transfer > Sync > Idle ("Ready").
///
/// All user-visible strings are passed in by the caller so that notifications
/// respect the selected locale.
///
/// Usage:
///   await BackgroundTransferService.instance.init();
///   await BackgroundTransferService.instance.startPersistentService(title: '...', text: '...');
///   BackgroundTransferService.instance.onTransferStarted(title: '...', text: '...');
///   BackgroundTransferService.instance.updateProgress(title: '...', text: '...');
///   BackgroundTransferService.instance.onTransferFinished();
class BackgroundTransferService {
  BackgroundTransferService._();

  static final BackgroundTransferService instance =
      BackgroundTransferService._();

  /// Number of currently active transfers.
  int _activeCount = 0;

  /// Whether sync watching is active (file watchers running / server listening).
  bool _syncActive = false;
  int _syncWatchCount = 0;

  bool _initialized = false;

  /// Whether the persistent (always-on) service is active.
  bool _persistentActive = false;

  /// Cached persistent notification strings (idle "ready" state).
  String _persistentNotifTitle = 'LifeOS AnyWhere';
  String _persistentNotifText = 'Ready';

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

  // ────────────────────────────────────────────────────────────────────────
  // Persistent (always-on) service
  // ────────────────────────────────────────────────────────────────────────

  /// Starts the persistent foreground service at app launch.
  /// The service will **never** be stopped while the app is open.
  ///
  /// [title] and [text] are the idle "ready" notification strings.
  Future<void> startPersistentService({
    required String title,
    required String text,
  }) async {
    if (_persistentActive) return;

    _persistentNotifTitle = title;
    _persistentNotifText = text;

    // Enable wakelock on all platforms.
    try {
      await WakelockPlus.enable();
      _log.debug('Wakelock enabled (persistent)');
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
        _log.info('Persistent foreground service started');
      } catch (e) {
        _log.warning('Failed to start persistent foreground service: $e');
      }
    }

    _persistentActive = true;
  }

  /// Updates the persistent (idle) notification strings. Call when the locale
  /// changes so the notification text stays current.
  void updatePersistentNotifStrings({
    required String title,
    required String text,
  }) {
    _persistentNotifTitle = title;
    _persistentNotifText = text;
    // If currently in idle state, refresh the notification now.
    if (_activeCount == 0 && !_syncActive && Platform.isAndroid) {
      _showIdleNotification();
    }
  }

  // ────────────────────────────────────────────────────────────────────────
  // Transfer lifecycle — only updates the notification, never start/stop
  // ────────────────────────────────────────────────────────────────────────

  /// Call when a new transfer starts. Updates the notification to show
  /// transfer info. The persistent service is already running.
  ///
  /// [title] and [text] are localised notification strings provided by the caller.
  Future<void> onTransferStarted({
    required String title,
    required String text,
  }) async {
    _activeCount++;
    _log.debug('Transfer started (active: $_activeCount)');

    if (Platform.isAndroid) {
      try {
        await FlutterForegroundTask.updateService(
          notificationTitle: title,
          notificationText: text,
        );
      } catch (e) {
        _log.warning('Failed to update notification for transfer: $e');
      }
    }
  }

  /// Call when a transfer completes, fails, or is cancelled. Reverts the
  /// notification to sync or idle state when no transfers remain.
  Future<void> onTransferFinished() async {
    _activeCount = (_activeCount - 1).clamp(0, 999);
    _log.debug('Transfer finished (active: $_activeCount)');

    if (_activeCount == 0 && Platform.isAndroid) {
      if (_syncActive) {
        // Sync still active — show sync notification.
        _updateSyncNotification();
      } else {
        // Back to idle — show "Ready" notification.
        _showIdleNotification();
      }
    }
    // If _activeCount > 0, caller will call updateProgress next.
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
  // Sync foreground service — updates notification while watching folders
  // ────────────────────────────────────────────────────────────────────────

  /// Call when a sync watcher starts (job enters watching phase).
  /// Updates the notification if no transfer is active.
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

    if (_activeCount == 0 && Platform.isAndroid) {
      // No transfer active — show sync notification.
      _updateSyncNotification();
    }
    // If transfer active, it takes priority — notification unchanged.
  }

  /// Call when a sync watcher stops.
  /// Reverts the notification to idle if no more watchers or transfers active.
  Future<void> onSyncWatchStopped() async {
    _syncWatchCount = (_syncWatchCount - 1).clamp(0, 999);
    if (_syncWatchCount == 0) _syncActive = false;
    _log.debug('Sync watch stopped (watching: $_syncWatchCount)');

    if (_syncWatchCount == 0 && _activeCount == 0 && Platform.isAndroid) {
      // Nothing active — revert to idle notification.
      _showIdleNotification();
    } else if (Platform.isAndroid && _activeCount == 0) {
      // Still some sync watchers — update sync notification.
      _updateSyncNotification();
    }
    // If transfers active, notification unchanged.
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

  // ────────────────────────────────────────────────────────────────────────
  // Private helpers
  // ────────────────────────────────────────────────────────────────────────

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

  /// Reverts the notification to the idle "Ready" state.
  void _showIdleNotification() {
    if (!Platform.isAndroid) return;
    try {
      FlutterForegroundTask.updateService(
        notificationTitle: _persistentNotifTitle,
        notificationText: _persistentNotifText,
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
