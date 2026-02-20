import 'dart:io';

import 'package:anyware/core/logger.dart';
import 'package:local_notifier/local_notifier.dart';
import 'package:window_manager/window_manager.dart';

/// Manages Windows toast notifications for file transfer events.
///
/// Only functional on Windows. On other platforms all methods are no-ops.
class WindowsNotificationService {
  WindowsNotificationService._();

  static final _log = AppLogger('Notification');

  static final WindowsNotificationService instance =
      WindowsNotificationService._();

  bool _initialized = false;

  /// Initializes the local notifier. Call once during app startup.
  Future<void> init() async {
    if (!Platform.isWindows) return;
    if (_initialized) return;

    try {
      await localNotifier.setup(
        appName: 'LifeOS AnyWhere',
        shortcutPolicy: ShortcutPolicy.requireCreate,
      );
      _initialized = true;
    } catch (e) {
      _log.error('Failed to initialize: $e', error: e);
    }
  }

  /// Shows a notification when an incoming transfer starts.
  void notifyTransferStarted(String fileName, String senderName) {
    _show(
      title: 'LifeOS AnyWhere',
      body: '$senderName \u2192 $fileName',
    );
  }

  /// Shows a notification when a transfer completes successfully.
  void notifyTransferCompleted(String fileName) {
    _show(
      title: 'LifeOS AnyWhere',
      body: '\u2705 $fileName',
    );
  }

  /// Shows a notification when a transfer fails.
  void notifyTransferFailed(String fileName) {
    _show(
      title: 'LifeOS AnyWhere',
      body: '\u274c $fileName',
    );
  }

  /// Shows a summary notification when a sync batch completes.
  void notifySyncCompleted(int fileCount, String deviceName, String jobName) {
    _show(
      title: 'LifeOS AnyWhere',
      body: '\u2705 $jobName: $fileCount files \u2192 $deviceName',
    );
  }

  void _show({required String title, required String body}) {
    if (!Platform.isWindows || !_initialized) return;

    try {
      final notification = LocalNotification(
        title: title,
        body: body,
      );

      // When user clicks the notification, bring the window to front.
      notification.onClick = () {
        windowManager.show();
        windowManager.focus();
      };

      notification.show();
    } catch (e) {
      _log.warning('Failed to show notification: $e');
    }
  }
}
