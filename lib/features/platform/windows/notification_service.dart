import 'dart:io';

import 'package:anyware/core/logger.dart';
import 'package:local_notifier/local_notifier.dart';
import 'package:window_manager/window_manager.dart';

/// Manages native desktop notifications on Windows, Linux, and macOS.
///
/// Callers are responsible for providing localised strings.
class DesktopNotificationService {
  DesktopNotificationService._();

  static final _log = AppLogger('Notification');

  static final DesktopNotificationService instance =
      DesktopNotificationService._();

  bool get _isDesktop =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  bool _initialized = false;

  /// Initializes the local notifier. Call once during app startup.
  Future<void> init() async {
    if (!_isDesktop) return;
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
  void notify({
    required String title,
    required String body,
    void Function()? onClick,
  }) {
    _show(title: title, body: body, onClick: onClick);
  }

  void _show({
    required String title,
    required String body,
    void Function()? onClick,
  }) {
    if (!_isDesktop || !_initialized) return;

    try {
      final notification = LocalNotification(title: title, body: body);

      // When user clicks the notification, bring the window to front.
      notification.onClick = () {
        windowManager.show();
        windowManager.focus();
        onClick?.call();
      };

      notification.show();
    } catch (e) {
      _log.warning('Failed to show notification: $e');
    }
  }
}
