import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'package:anyware/core/logger.dart';

/// Platform-agnostic system tray service.
///
/// Supports Windows, Linux, and macOS using the `tray_manager` package.
/// On unsupported platforms (Android, iOS) this is a no-op.
///
/// **Linux notes:**
/// - Uses `libappindicator` / `libayatana-appindicator` via the native plugin.
/// - Click events (`onTrayIconMouseDown`, `onTrayIconRightMouseDown`) are NOT
///   supported by AppIndicator — the context menu is shown natively on left
///   click by the indicator itself.
/// - `popUpContextMenu()` is NOT implemented on Linux.
/// - On GNOME 42+, the "AppIndicator and KStatusNotifierItem Support" shell
///   extension must be installed for the tray icon to appear.
/// - On KDE / XFCE / MATE, AppIndicator works natively.
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
      final iconPath = _resolveIconPath();
      _log.info('Using tray icon: $iconPath');

      await trayManager.setIcon(iconPath);

      // setToolTip is only implemented on Windows; skip on other platforms
      // to avoid MissingPluginException.
      if (Platform.isWindows) {
        await trayManager.setToolTip('LifeOS AnyWhere');
      }

      // Build context menu.
      final menu = Menu(
        items: [
          MenuItem(
            key: 'show',
            label: 'Show LifeOS AnyWhere',
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
  ///
  /// **Note:** This event only fires on Windows. On Linux (AppIndicator),
  /// the left click natively opens the context menu instead.
  @override
  void onTrayIconMouseDown() {
    _showAndFocusWindow();
  }

  /// Called when the tray icon is clicked with the right mouse button.
  ///
  /// **Note:** This event only fires on Windows. On Linux, the context menu
  /// is handled natively by AppIndicator.
  @override
  void onTrayIconRightMouseDown() {
    // popUpContextMenu() is only implemented on Windows.
    if (Platform.isWindows) {
      trayManager.popUpContextMenu();
    }
  }

  /// Called when a context menu item is clicked.
  ///
  /// This works on ALL platforms (Windows, Linux, macOS).
  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    _log.info('Tray menu item clicked: ${menuItem.key}');
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
  /// **Windows**: Returns an absolute path to `app_icon.ico` next to the
  /// executable. The `tray_manager` Dart code calls `path.joinAll` with
  /// `data/flutter_assets` prefix, but an absolute path overrides the prefix
  /// on Windows (`path.joinAll` discards earlier segments when it encounters
  /// an absolute component).
  ///
  /// **Linux**: `tray_manager` always prepends `<exe_dir>/data/flutter_assets/`
  /// to the icon path on non-sandbox Linux. Therefore we return a **relative
  /// asset path** (e.g., `assets/icons/logo.png`) so the final resolved path
  /// becomes `<exe_dir>/data/flutter_assets/assets/icons/logo.png` — which is
  /// where Flutter bundles the asset.
  ///
  /// **macOS**: Uses `rootBundle.load()` so the path should be a Flutter asset.
  String _resolveIconPath() {
    if (Platform.isWindows) {
      final exeDir = p.dirname(Platform.resolvedExecutable);
      final releaseIco = p.join(exeDir, 'app_icon.ico');
      if (File(releaseIco).existsSync()) return releaseIco;
      // Debug fallback: relative path from project root.
      return p.join('windows', 'runner', 'resources', 'app_icon.ico');
    }

    // Linux & macOS: return the Flutter asset path.
    // tray_manager will prepend <exe_dir>/data/flutter_assets/ on Linux,
    // and use rootBundle.load() on macOS.
    //
    // First check if the logo exists as a bundled Flutter asset.
    final exeDir = p.dirname(Platform.resolvedExecutable);
    final bundledAsset = p.join(
      exeDir, 'data', 'flutter_assets', 'assets', 'icons', 'logo.png',
    );
    if (File(bundledAsset).existsSync()) {
      return 'assets/icons/logo.png';
    }

    // Fallback: check if logo.png is next to the binary (e.g., .deb package).
    // In this case we return the absolute path — path.joinAll with an absolute
    // component discards the prefix.
    final logoPng = p.join(exeDir, 'logo.png');
    if (File(logoPng).existsSync()) return logoPng;

    // Last resort: relative asset path (works in debug if asset is registered).
    return 'assets/icons/logo.png';
  }
}
