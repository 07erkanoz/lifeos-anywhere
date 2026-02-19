import 'dart:io';

import 'package:launch_at_startup/launch_at_startup.dart';

/// Manages automatic launch at system startup on Windows.
///
/// Uses the [launch_at_startup] package to register/unregister the
/// application for automatic start when the user logs in.
class WindowsStartupService {
  WindowsStartupService();

  bool _isSetup = false;

  /// Whether the startup service has been set up.
  bool get isSetup => _isSetup;

  /// Configures the launch_at_startup package with the app name and path.
  ///
  /// Must be called before [enable], [disable], or [isEnabled].
  /// Only functional on Windows. On other platforms this is a no-op.
  void setup() {
    if (!Platform.isWindows) return;

    launchAtStartup.setup(
      appName: 'LifeOS AnyWhere',
      appPath: Platform.resolvedExecutable,
      args: ['--minimized'],
    );

    _isSetup = true;
  }

  /// Enables automatic launch at system startup.
  ///
  /// Registers the application so it starts when the user logs in.
  /// [setup] must be called first.
  Future<void> enable() async {
    if (!Platform.isWindows || !_isSetup) return;

    await launchAtStartup.enable();
  }

  /// Disables automatic launch at system startup.
  ///
  /// Removes the application from the startup registry.
  /// [setup] must be called first.
  Future<void> disable() async {
    if (!Platform.isWindows || !_isSetup) return;

    await launchAtStartup.disable();
  }

  /// Returns whether the application is currently set to launch at startup.
  ///
  /// Returns `false` if the service has not been set up or if not on Windows.
  Future<bool> isEnabled() async {
    if (!Platform.isWindows || !_isSetup) return false;

    return await launchAtStartup.isEnabled();
  }
}
