import 'dart:io';

import 'package:anyware/core/logger.dart';
import 'package:local_notifier/local_notifier.dart';
import 'package:window_manager/window_manager.dart';

/// Manages Windows toast notifications for file transfer events.
///
/// Only functional on Windows. On other platforms all methods are no-ops.
/// Callers are responsible for providing localised strings.
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

  /// Shows a toast notification with the given [title] and [body].
  ///
  /// Callers are responsible for providing localised strings.
  void notify({required String title, required String body}) {
    _show(title: title, body: body);
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
