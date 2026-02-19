import 'dart:io';

import 'package:anyware/core/logger.dart';
import 'package:window_manager/window_manager.dart';

import 'package:anyware/core/constants.dart';
import 'package:anyware/features/platform/windows/tray_service.dart';
import 'package:anyware/features/platform/windows/startup_service.dart';
import 'package:anyware/features/platform/windows/context_menu_service.dart';
import 'package:anyware/features/settings/domain/settings.dart';

/// Top-level Windows platform service that orchestrates the tray, startup,
/// and context menu sub-services.
///
/// Usage:
/// ```dart
/// final windowsService = WindowsService();
/// await windowsService.init(settings);
/// windowsService.handleStartupArgs(args);
/// ```
///
/// Only operational on Windows. All methods are safe no-ops on other platforms.
class WindowsService with WindowListener {
  WindowsService();

  static final _log = AppLogger('WindowsService');

  final WindowsTrayService _trayService = WindowsTrayService();
  final WindowsStartupService _startupService = WindowsStartupService();
  final WindowsContextMenuService _contextMenuService =
      WindowsContextMenuService();

  /// Exposes the tray service for external access if needed.
  WindowsTrayService get trayService => _trayService;

  /// Exposes the startup service for external access if needed.
  WindowsStartupService get startupService => _startupService;

  /// Exposes the context menu service for external access if needed.
  WindowsContextMenuService get contextMenuService => _contextMenuService;

  /// Callback invoked when a file is shared via Explorer context menu.
  ///
  /// Set this before calling [handleStartupArgs] to handle incoming shares.
  void Function(String filePath)? onShareReceived;

  bool _isInitialized = false;

  /// Whether the Windows service has been initialized.
  bool get isInitialized => _isInitialized;

  /// Initializes all Windows platform services based on [settings].
  ///
  /// - Ensures [windowManager] is initialized.
  /// - Sets up the system tray if [AppSettings.minimizeToTray] is enabled.
  /// - Configures launch-at-startup if [AppSettings.launchAtStartup] is enabled.
  /// - Registers Explorer context menu if [AppSettings.showInExplorerMenu] is enabled.
  ///
  /// Only functional on Windows. On other platforms this is a no-op.
  Future<void> init(AppSettings settings) async {
    if (!Platform.isWindows) return;

    // Ensure the window manager is ready.
    await windowManager.ensureInitialized();
    windowManager.addListener(this);

    // System tray setup.
    if (settings.minimizeToTray) {
      await _trayService.initTray();
      await _trayService.setupCloseToTray();
    }

    // Launch at startup setup.
    _startupService.setup();
    if (settings.launchAtStartup) {
      await _startupService.enable();
    } else {
      await _startupService.disable();
    }

    // Explorer context menu setup.
    if (settings.showInExplorerMenu) {
      _contextMenuService.ensureUpToDate();
    } else {
      _contextMenuService.unregister();
    }

    // Ensure Windows Firewall allows our discovery & transfer ports.
    await _ensureFirewallRules();

    _isInitialized = true;
  }

  /// Handles command-line arguments passed at application startup.
  ///
  /// Recognized flags:
  /// - `--minimized`: The window should remain hidden (started via startup).
  /// - `--share <path>`: A file or directory was shared from Explorer.
  ///
  /// Returns `true` if the window should be shown, `false` if it should
  /// stay hidden (e.g., when launched with `--minimized`).
  bool handleStartupArgs(List<String> args) {
    if (!Platform.isWindows) return true;

    bool shouldShowWindow = true;

    // Check for --minimized flag (launched at startup).
    if (args.contains('--minimized')) {
      shouldShowWindow = false;
    }

    // Check for --share flag (launched from Explorer context menu).
    final shareIndex = args.indexOf('--share');
    if (shareIndex != -1 && shareIndex + 1 < args.length) {
      final filePath = args[shareIndex + 1];
      _log.info('Share received for: $filePath');

      if (onShareReceived != null) {
        onShareReceived!(filePath);
      }

      // When sharing, we want to show the window.
      shouldShowWindow = true;
    }

    return shouldShowWindow;
  }

  /// Called when the user clicks the window close button.
  ///
  /// If the tray service is active, the window is hidden instead of closed,
  /// allowing the app to keep running in the system tray.
  @override
  void onWindowClose() {
    if (_trayService.isInitialized) {
      windowManager.hide();
    }
  }

  // ---------------------------------------------------------------------------
  // Firewall
  // ---------------------------------------------------------------------------

  static const _firewallRuleName = 'LifeOS AnyWhere';

  /// Ensures Windows Firewall inbound rules exist for the discovery (UDP)
  /// and file transfer (TCP) ports.
  ///
  /// First checks if the rule already exists (no admin needed). If not,
  /// uses PowerShell `Start-Process -Verb RunAs` to trigger a UAC prompt
  /// and add the rules with elevation.
  Future<void> _ensureFirewallRules() async {
    try {
      final discoveryPort = AppConstants.discoveryPort;
      final transferPort = AppConstants.defaultPort;

      // Check if our firewall rules already exist WITH the correct ports.
      bool discoveryOk = false;
      bool transferOk = false;

      final discCheck = await Process.run('netsh', [
        'advfirewall', 'firewall', 'show', 'rule',
        'name=$_firewallRuleName Discovery',
      ]);
      if (discCheck.exitCode == 0) {
        final output = discCheck.stdout.toString();
        discoveryOk = output.contains('$discoveryPort');
      }

      final transCheck = await Process.run('netsh', [
        'advfirewall', 'firewall', 'show', 'rule',
        'name=$_firewallRuleName Transfer',
      ]);
      if (transCheck.exitCode == 0) {
        final output = transCheck.stdout.toString();
        transferOk = output.contains('$transferPort');
      }

      if (discoveryOk && transferOk) {
        _log.debug('Firewall rules already correct.');
        return;
      }

      _log.info('Firewall rules need update '
          '(discovery=$discoveryOk, transfer=$transferOk), requesting admin...');

      // Write a temporary .bat file that:
      // 1. Deletes any old rules with our name (in case ports changed)
      // 2. Adds fresh rules with the current ports
      final tempDir = Directory.systemTemp;
      final batFile = File('${tempDir.path}\\lifeos_firewall.bat');

      await batFile.writeAsString(
        '@echo off\r\n'
        'netsh advfirewall firewall delete rule name="$_firewallRuleName Discovery" >nul 2>&1\r\n'
        'netsh advfirewall firewall delete rule name="$_firewallRuleName Transfer" >nul 2>&1\r\n'
        'netsh advfirewall firewall add rule '
        'name="$_firewallRuleName Discovery" '
        'dir=in action=allow protocol=UDP localport=$discoveryPort '
        'enable=yes profile=private,domain,public\r\n'
        'netsh advfirewall firewall add rule '
        'name="$_firewallRuleName Transfer" '
        'dir=in action=allow protocol=TCP localport=$transferPort '
        'enable=yes profile=private,domain,public\r\n',
      );

      _log.debug('Wrote firewall script to ${batFile.path}');

      // Run the .bat file elevated — this triggers the UAC prompt.
      final result = await Process.run('powershell', [
        '-NoProfile',
        '-Command',
        'Start-Process',
        '-FilePath', batFile.path,
        '-Verb', 'RunAs',
        '-Wait',
      ]);

      // Clean up the temp file.
      try {
        await batFile.delete();
      } catch (_) {}

      if (result.exitCode == 0) {
        _log.info('Firewall rules updated successfully.');
      } else {
        _log.warning(
          'Firewall configuration failed or was declined '
          '(exit code: ${result.exitCode}). stderr: ${result.stderr}',
        );
      }
    } catch (e) {
      _log.error('Firewall rule setup error: $e', error: e);
    }
  }

  /// Cleans up all sub-services and removes the window listener.
  ///
  /// Should be called when the application is shutting down.
  Future<void> dispose() async {
    if (!Platform.isWindows || !_isInitialized) return;

    windowManager.removeListener(this);
    await _trayService.dispose();

    _isInitialized = false;
  }
}
