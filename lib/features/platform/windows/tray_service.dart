import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

/// Manages the system tray icon and its context menu on Windows.
///
/// Provides functionality to minimize the application to the system tray
/// instead of closing it, and offers a context menu for quick actions.
class WindowsTrayService with TrayListener {
  WindowsTrayService();

  /// Callback invoked before the application exits via the tray menu.
  /// Use this to perform cleanup (stop services, save state, etc.).
  Future<void> Function()? onBeforeExit;

  bool _isInitialized = false;

  /// Whether the tray service has been initialized.
  bool get isInitialized => _isInitialized;

  /// Initializes the system tray icon, tooltip, context menu, and event handlers.
  ///
  /// Only functional on Windows. On other platforms this is a no-op.
  Future<void> initTray() async {
    if (!Platform.isWindows) return;

    // Resolve the tray icon path relative to the executable.
    // In debug mode the working dir is the project root, so we use the source path.
    // In release mode the ico is installed next to the exe by CMakeLists.txt.
    final exeDir = p.dirname(Platform.resolvedExecutable);
    final releaseIconPath = p.join(exeDir, 'app_icon.ico');
    const debugIconPath = 'windows/runner/resources/app_icon.ico';

    final iconPath = File(releaseIconPath).existsSync()
        ? releaseIconPath
        : debugIconPath;

    await trayManager.setIcon(iconPath);

    // Set the tooltip shown on hover.
    await trayManager.setToolTip('LifeOS AnyWhere');

    // Build the context menu.
    final menu = Menu(
      items: [
        MenuItem(
          key: 'show',
          label: 'Goster / Show',
        ),
        MenuItem.separator(),
        MenuItem(
          key: 'exit',
          label: 'Cikis / Exit',
        ),
      ],
    );
    await trayManager.setContextMenu(menu);

    // Register this instance as a tray event listener.
    trayManager.addListener(this);

    _isInitialized = true;
  }

  /// Configures the window to hide (minimize to tray) instead of closing.
  ///
  /// When the user clicks the close button, the window is hidden rather than
  /// destroyed. The application continues running in the system tray.
  Future<void> setupCloseToTray() async {
    if (!Platform.isWindows) return;

    await windowManager.setPreventClose(true);
  }

  /// Called when the tray icon is clicked with the left mouse button.
  ///
  /// Shows the main window and brings it to focus.
  @override
  void onTrayIconMouseDown() {
    _showAndFocusWindow();
  }

  /// Called when the tray icon is clicked with the right mouse button.
  ///
  /// Displays the context menu at the cursor position.
  @override
  void onTrayIconRightMouseDown() {
    trayManager.popUpContextMenu();
  }

  /// Called when a context menu item is clicked.
  ///
  /// Handles the "show" and "exit" menu actions.
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

  /// Cleans up the tray listener and removes the tray icon.
  Future<void> dispose() async {
    if (!Platform.isWindows || !_isInitialized) return;

    trayManager.removeListener(this);
    await trayManager.destroy();

    _isInitialized = false;
  }
}
