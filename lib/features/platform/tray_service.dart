import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'package:anyware/core/logger.dart';

/// Platform-agnostic system tray service.
///
/// Supports Windows, Linux, and macOS using the `tray_manager` package.
/// On unsupported platforms (Android, iOS) this is a no-op.
class AppTrayService with TrayListener {
  AppTrayService();

  static final _log = AppLogger('Tray');

  /// Callback invoked before the application exits via the tray menu.
  Future<void> Function()? onBeforeExit;

  bool _isInitialized = false;

  /// Whether the tray service has been initialized.
  bool get isInitialized => _isInitialized;

  /// Whether the current platform supports system tray.
  static bool get isSupported =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  /// Initializes the system tray icon, tooltip, context menu, and event handlers.
  Future<void> initTray() async {
    if (!isSupported) return;

    try {
      // Resolve icon path based on platform and build mode.
      final iconPath = _resolveIconPath();

      await trayManager.setIcon(iconPath);
      await trayManager.setToolTip('LifeOS AnyWhere');

      // Build context menu.
      final menu = Menu(
        items: [
          MenuItem(
            key: 'show',
            label: 'Show',
          ),
          MenuItem.separator(),
          MenuItem(
            key: 'exit',
            label: 'Exit',
          ),
        ],
      );
      await trayManager.setContextMenu(menu);

      // Register this instance as a tray event listener.
      trayManager.addListener(this);

      _isInitialized = true;
      _log.info('System tray initialized on ${Platform.operatingSystem}');
    } catch (e) {
      _log.error('Failed to initialize system tray: $e', error: e);
    }
  }

  /// Configures the window to hide (minimize to tray) instead of closing.
  Future<void> setupCloseToTray() async {
    if (!isSupported) return;
    await windowManager.setPreventClose(true);
  }

  /// Called when the tray icon is clicked with the left mouse button.
  @override
  void onTrayIconMouseDown() {
    _showAndFocusWindow();
  }

  /// Called when the tray icon is clicked with the right mouse button.
  @override
  void onTrayIconRightMouseDown() {
    trayManager.popUpContextMenu();
  }

  /// Called when a context menu item is clicked.
  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'show':
        _showAndFocusWindow();
        break;
      case 'exit':
        _exitApplication();
        break;
    }
  }

  /// Shows the main window and brings it to the foreground.
  Future<void> _showAndFocusWindow() async {
    await windowManager.show();
    await windowManager.focus();
  }

  /// Runs cleanup, disables close prevention, and destroys the window.
  Future<void> _exitApplication() async {
    if (onBeforeExit != null) {
      await onBeforeExit!();
    }
    await windowManager.setPreventClose(false);
    await windowManager.destroy();
  }

  /// Cleans up the tray and removes the icon.
  Future<void> dispose() async {
    if (!isSupported || !_isInitialized) return;
    trayManager.removeListener(this);
    await trayManager.destroy();
    _isInitialized = false;
  }

  /// Resolves the tray icon path based on platform.
  ///
  /// - **Windows**: Uses `.ico` format.
  /// - **Linux/macOS**: Uses `.png` format.
  String _resolveIconPath() {
    final exeDir = p.dirname(Platform.resolvedExecutable);

    if (Platform.isWindows) {
      final releaseIco = p.join(exeDir, 'app_icon.ico');
      if (File(releaseIco).existsSync()) return releaseIco;
      return 'windows/runner/resources/app_icon.ico';
    }

    // Linux & macOS — use PNG.
    // In release: logo.png installed next to binary in /opt/lifeos-anywhere/
    final logoPng = p.join(exeDir, 'logo.png');
    if (File(logoPng).existsSync()) return logoPng;

    // Try flutter_assets path.
    final assetsPng = p.join(exeDir, 'data', 'flutter_assets', 'assets', 'icons', 'app_icon.png');
    if (File(assetsPng).existsSync()) return assetsPng;

    // Debug fallback.
    return 'logo.png';
  }
}
