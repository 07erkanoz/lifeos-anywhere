import 'dart:async';
import 'dart:io';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'package:anyware/core/logger.dart';

final _log = AppLogger('BackgroundService');

/// Keeps Android awake only while a transfer or folder watcher is active.
///
/// Idle foreground services and permanent CPU/Wi-Fi locks cause severe battery
/// drain. The service is therefore started on demand and stopped as soon as
/// there is no active transfer or sync watcher.
///
/// Notification priority: Transfer > Sync.
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

  /// Number of currently active transfers.
  int _activeCount = 0;

  /// Whether sync watching is active (file watchers running / server listening).
  bool _syncActive = false;
  int _syncWatchCount = 0;

  bool _initialized = false;

  bool _serviceActive = false;
  Future<void>? _serviceStartFuture;

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

    // Clean up the previous always-on implementation after an app upgrade or
    // hot restart. No active transfer can survive a fresh Flutter startup.
    try {
      if (await FlutterForegroundTask.isRunningService) {
        await FlutterForegroundTask.stopService();
      }
    } catch (e) {
      _log.warning('Could not stop stale foreground service: $e');
    }

    _log.info('Foreground task configured');
  }

  // ────────────────────────────────────────────────────────────────────────
  // Transfer lifecycle
  // ────────────────────────────────────────────────────────────────────────

  /// Call when a new transfer starts. Updates the notification to show
  /// transfer info and starts the foreground service on demand.
  ///
  /// [title] and [text] are localised notification strings provided by the caller.
  Future<void> onTransferStarted({
    required String title,
    required String text,
  }) async {
    _activeCount++;
    _log.debug('Transfer started (active: $_activeCount)');

    if (Platform.isAndroid) {
      await _ensureService(title: title, text: text);
    }
  }

  /// Call when a transfer completes, fails, or is cancelled. Reverts the
  /// notification to sync or idle state when no transfers remain.
  Future<void> onTransferFinished() async {
    _activeCount = (_activeCount - 1).clamp(0, 999);
    _log.debug('Transfer finished (active: $_activeCount)');

    if (_activeCount == 0 && Platform.isAndroid) {
      if (_syncActive) {
        _updateSyncNotification();
      } else {
        await _stopServiceIfIdle();
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
      if (!_serviceActive && _serviceStartFuture != null) {
        await _serviceStartFuture;
      }
      if (!_serviceActive) return;
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
      await _ensureService(title: title, text: text);
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
      await _stopServiceIfIdle();
    } else if (Platform.isAndroid && _activeCount == 0) {
      // Still some sync watchers — update sync notification.
      _updateSyncNotification();
    }
    // If transfers active, notification unchanged.
  }

  /// Updates the sync notification title/text. Call this when the locale
  /// changes while sync is active so the notification text stays current.
  void updateSyncNotifStrings({required String title, required String text}) {
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
    if (!Platform.isAndroid || !_serviceActive) return;
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

  Future<void> _ensureService({
    required String title,
    required String text,
  }) async {
    if (!Platform.isAndroid) return;

    if (_serviceActive) {
      await FlutterForegroundTask.updateService(
        notificationTitle: title,
        notificationText: text,
      );
      return;
    }

    final pending = _serviceStartFuture;
    if (pending != null) {
      await pending;
      if (_serviceActive) {
        await FlutterForegroundTask.updateService(
          notificationTitle: title,
          notificationText: text,
        );
      }
      return;
    }

    final start = _startService(title: title, text: text);
    _serviceStartFuture = start;
    try {
      await start;
    } finally {
      _serviceStartFuture = null;
    }
  }

  Future<void> _startService({
    required String title,
    required String text,
  }) async {
    try {
      if (await FlutterForegroundTask.isRunningService) {
        _serviceActive = true;
        await FlutterForegroundTask.updateService(
          notificationTitle: title,
          notificationText: text,
        );
        return;
      }

      await FlutterForegroundTask.startService(
        notificationTitle: title,
        notificationText: text,
        callback: _foregroundTaskCallback,
      );
      _serviceActive = await FlutterForegroundTask.isRunningService;
      if (_serviceActive) {
        _log.info('Foreground service started for active work');
      } else {
        _log.warning('Foreground service did not enter running state');
      }
    } catch (e) {
      _serviceActive = false;
      _log.warning('Failed to start foreground service: $e');
    }
  }

  Future<void> _stopServiceIfIdle() async {
    if (!Platform.isAndroid || _activeCount > 0 || _syncActive) return;
    final pending = _serviceStartFuture;
    if (pending != null) await pending;
    if (!_serviceActive && !await FlutterForegroundTask.isRunningService) {
      return;
    }
    try {
      await FlutterForegroundTask.stopService();
      _log.info('Foreground service stopped while idle');
    } catch (e) {
      _log.warning('Failed to stop idle foreground service: $e');
    } finally {
      _serviceActive = false;
    }
  }

  Future<void> shutdown() async {
    _activeCount = 0;
    _syncWatchCount = 0;
    _syncActive = false;
    await _stopServiceIfIdle();
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
