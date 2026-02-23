import 'dart:io';

import 'package:anyware/core/logger.dart';
import 'package:flutter/services.dart';

// Platform-agnostic background sync scheduler.
//
// On Android it delegates to WorkManager via a MethodChannel.
// On iOS it delegates to BGProcessingTask via a MethodChannel.
// On desktop platforms the existing in-process Timer (inside SyncService) is
// sufficient, so this class is effectively a no-op there.
class SyncScheduler {
  SyncScheduler._();
  static final SyncScheduler instance = SyncScheduler._();

  static final _log = AppLogger('SyncScheduler');

  static const _channel = MethodChannel('com.lifeos.anywhere/sync_scheduler');

  /// Minimum periodic interval on Android (WorkManager limitation).
  static const _androidMinIntervalMinutes = 15;

  bool _initialized = false;

  // ─── Initialization ──────────────────────────────────────────────

  /// Call once during app startup (e.g. in main.dart).
  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    if (Platform.isAndroid) {
      try {
        await _channel.invokeMethod('initialize');
        _log.info('Android WorkManager initialized');
      } on MissingPluginException {
        _log.warning('WorkManager plugin not available on this platform');
      } catch (e) {
        _log.warning('WorkManager init failed: $e');
      }
    } else if (Platform.isIOS) {
      try {
        await _channel.invokeMethod('initialize');
        _log.info('iOS BGProcessingTask initialized');
      } on MissingPluginException {
        _log.warning('BGProcessingTask plugin not available on this platform');
      } catch (e) {
        _log.warning('iOS background init failed: $e');
      }
    }
    // Desktop: no-op — SyncService's internal Timer handles scheduling.
  }

  // ─── Register / Unregister periodic sync ────────────────────────

  /// Registers a periodic background sync task for [jobId].
  ///
  /// [intervalMinutes] is the desired repeat interval. Android rounds up to
  /// 15 minutes minimum. iOS may schedule tasks at system discretion.
  Future<void> registerPeriodicSync({
    required String jobId,
    int intervalMinutes = 30,
    bool requiresWifi = true,
    bool requiresCharging = false,
  }) async {
    if (Platform.isAndroid) {
      await _registerAndroid(
        jobId: jobId,
        intervalMinutes: intervalMinutes,
        requiresWifi: requiresWifi,
        requiresCharging: requiresCharging,
      );
    } else if (Platform.isIOS) {
      await _registerIOS(
        jobId: jobId,
        intervalMinutes: intervalMinutes,
      );
    }
    // Desktop: no-op.
  }

  /// Cancels a previously registered periodic sync task.
  Future<void> cancelPeriodicSync(String jobId) async {
    if (Platform.isAndroid || Platform.isIOS) {
      try {
        await _channel.invokeMethod('cancelPeriodicSync', {
          'jobId': jobId,
        });
        _log.info('Cancelled periodic sync for job $jobId');
      } on MissingPluginException {
        // Expected on platforms without native plugin.
      } catch (e) {
        _log.warning('Cancel periodic sync failed for $jobId: $e');
      }
    }
  }

  /// Cancels all registered periodic sync tasks.
  Future<void> cancelAll() async {
    if (Platform.isAndroid || Platform.isIOS) {
      try {
        await _channel.invokeMethod('cancelAll');
        _log.info('Cancelled all periodic sync tasks');
      } on MissingPluginException {
        // Expected on platforms without native plugin.
      } catch (e) {
        _log.warning('Cancel all periodic syncs failed: $e');
      }
    }
  }

  // ─── Android (WorkManager) ──────────────────────────────────────

  Future<void> _registerAndroid({
    required String jobId,
    required int intervalMinutes,
    required bool requiresWifi,
    required bool requiresCharging,
  }) async {
    final effectiveInterval =
        intervalMinutes < _androidMinIntervalMinutes
            ? _androidMinIntervalMinutes
            : intervalMinutes;

    try {
      await _channel.invokeMethod('registerPeriodicSync', {
        'jobId': jobId,
        'intervalMinutes': effectiveInterval,
        'requiresWifi': requiresWifi,
        'requiresCharging': requiresCharging,
      });
      _log.info(
        'Android: registered periodic sync for $jobId '
        '(every ${effectiveInterval}m, wifi=$requiresWifi)',
      );
    } on MissingPluginException {
      _log.warning('WorkManager plugin not available');
    } catch (e) {
      _log.warning('Android register periodic sync failed: $e');
    }
  }

  // ─── iOS (BGProcessingTask) ─────────────────────────────────────

  Future<void> _registerIOS({
    required String jobId,
    required int intervalMinutes,
  }) async {
    try {
      await _channel.invokeMethod('registerPeriodicSync', {
        'jobId': jobId,
        'intervalMinutes': intervalMinutes,
      });
      _log.info('iOS: registered background processing for $jobId');
    } on MissingPluginException {
      _log.warning('iOS BGProcessingTask plugin not available');
    } catch (e) {
      _log.warning('iOS register background sync failed: $e');
    }
  }

  // ─── Status ─────────────────────────────────────────────────────

  /// Returns `true` if the platform supports background sync.
  bool get isSupported => Platform.isAndroid || Platform.isIOS;

  /// Returns human-readable platform info for UI display.
  String get platformInfo {
    if (Platform.isAndroid) return 'Android WorkManager (min 15 min)';
    if (Platform.isIOS) return 'iOS BGProcessingTask (system managed)';
    return 'Desktop (in-app timer)';
  }
}
