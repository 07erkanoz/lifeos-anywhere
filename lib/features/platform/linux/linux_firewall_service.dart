import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

typedef LinuxCommandRunner =
    Future<ProcessResult> Function(String executable, List<String> arguments);

enum LinuxFirewallBackend { ufw, firewalld }

enum LinuxFirewallState {
  notRequired,
  configured,
  needsAuthorization,
  deferred,
  unavailable,
}

class LinuxFirewallCheck {
  const LinuxFirewallCheck({
    required this.state,
    this.backend,
    this.helperPath,
    this.pkexecPath,
  });

  final LinuxFirewallState state;
  final LinuxFirewallBackend? backend;
  final String? helperPath;
  final String? pkexecPath;
}

class LinuxFirewallSetupResult {
  const LinuxFirewallSetupResult({
    required this.success,
    this.cancelled = false,
    this.details = '',
  });

  final bool success;
  final bool cancelled;
  final String details;
}

/// Handles the one-time Linux firewall authorization flow.
///
/// The privileged operations live in a fixed helper installed beside the
/// executable. This class only detects the active firewall and invokes that
/// helper through Polkit (`pkexec`) after the user accepts the in-app prompt.
class LinuxFirewallService {
  LinuxFirewallService(
    this._prefs, {
    LinuxCommandRunner? commandRunner,
    bool? isLinux,
    String? executablePath,
    DateTime Function()? now,
    bool Function(String path)? pathExists,
  }) : _commandRunner = commandRunner ?? _runCommand,
       _isLinux = isLinux ?? Platform.isLinux,
       _executablePath = executablePath ?? Platform.resolvedExecutable,
       _now = now ?? DateTime.now,
       _pathExists = pathExists ?? FileSystemEntity.isFileSync;

  static const int _configurationVersion = 1;
  static const String _configuredVersionKey = 'linuxFirewallConfiguredVersion';
  static const String _configuredBackendKey = 'linuxFirewallBackend';
  static const String _lastPromptKey = 'linuxFirewallLastPromptMs';
  static const Duration _promptCooldown = Duration(days: 7);
  static const String _systemMarkerPath =
      '/var/lib/lifeos-anywhere/firewall-v1';

  final SharedPreferences _prefs;
  final LinuxCommandRunner _commandRunner;
  final bool _isLinux;
  final String _executablePath;
  final DateTime Function() _now;
  final bool Function(String path) _pathExists;

  static Future<ProcessResult> _runCommand(
    String executable,
    List<String> arguments,
  ) {
    return Process.run(executable, arguments);
  }

  Future<LinuxFirewallCheck> inspect() async {
    if (!_isLinux) {
      return const LinuxFirewallCheck(state: LinuxFirewallState.notRequired);
    }

    final backend = await _detectActiveBackend();
    if (backend == null) {
      return const LinuxFirewallCheck(state: LinuxFirewallState.notRequired);
    }

    final configuredVersion = _prefs.getInt(_configuredVersionKey) ?? 0;
    final configuredBackend = _prefs.getString(_configuredBackendKey);
    final hasSystemMarker = _pathExists(_systemMarkerPath);
    if (hasSystemMarker ||
        (configuredVersion >= _configurationVersion &&
            configuredBackend == backend.name)) {
      return LinuxFirewallCheck(
        state: LinuxFirewallState.configured,
        backend: backend,
      );
    }

    final helperPath = _resolveHelperPath();
    final pkexecPath = _resolveExecutable(const [
      '/usr/bin/pkexec',
      '/bin/pkexec',
    ]);
    if (helperPath == null || pkexecPath == null) {
      return LinuxFirewallCheck(
        state: LinuxFirewallState.unavailable,
        backend: backend,
      );
    }

    final lastPromptMs = _prefs.getInt(_lastPromptKey);
    if (lastPromptMs != null) {
      final lastPrompt = DateTime.fromMillisecondsSinceEpoch(lastPromptMs);
      if (_now().difference(lastPrompt) < _promptCooldown) {
        return LinuxFirewallCheck(
          state: LinuxFirewallState.deferred,
          backend: backend,
        );
      }
    }

    return LinuxFirewallCheck(
      state: LinuxFirewallState.needsAuthorization,
      backend: backend,
      helperPath: helperPath,
      pkexecPath: pkexecPath,
    );
  }

  Future<void> deferPrompt() {
    return _setLastPrompt();
  }

  Future<void> _setLastPrompt() async {
    await _prefs.setInt(_lastPromptKey, _now().millisecondsSinceEpoch);
  }

  Future<LinuxFirewallSetupResult> configure(LinuxFirewallCheck check) async {
    if (check.state != LinuxFirewallState.needsAuthorization ||
        check.backend == null ||
        check.helperPath == null ||
        check.pkexecPath == null) {
      return const LinuxFirewallSetupResult(
        success: false,
        details: 'Firewall authorization is not available.',
      );
    }

    await deferPrompt();

    try {
      final result = await _commandRunner(check.pkexecPath!, [
        check.helperPath!,
        'configure',
        check.backend!.name,
      ]);
      if (result.exitCode != 0) {
        return LinuxFirewallSetupResult(
          success: false,
          cancelled: result.exitCode == 126 || result.exitCode == 127,
          details: '${result.stderr}'.trim(),
        );
      }

      await _prefs.setInt(_configuredVersionKey, _configurationVersion);
      await _prefs.setString(_configuredBackendKey, check.backend!.name);
      return const LinuxFirewallSetupResult(success: true);
    } catch (error) {
      return LinuxFirewallSetupResult(
        success: false,
        details: error.toString(),
      );
    }
  }

  Future<LinuxFirewallBackend?> _detectActiveBackend() async {
    final ufwPath = _resolveExecutable(const [
      '/usr/bin/ufw',
      '/usr/sbin/ufw',
      '/sbin/ufw',
    ]);
    if (ufwPath != null && await _isSystemdUnitActive('ufw')) {
      return LinuxFirewallBackend.ufw;
    }

    final firewalldPath = _resolveExecutable(const [
      '/usr/bin/firewall-cmd',
      '/usr/sbin/firewall-cmd',
    ]);
    if (firewalldPath != null) {
      try {
        final result = await _commandRunner(firewalldPath, const ['--state']);
        if (result.exitCode == 0 && '${result.stdout}'.trim() == 'running') {
          return LinuxFirewallBackend.firewalld;
        }
      } catch (_) {}
    }

    return null;
  }

  Future<bool> _isSystemdUnitActive(String unit) async {
    final systemctlPath = _resolveExecutable(const [
      '/usr/bin/systemctl',
      '/bin/systemctl',
    ]);
    if (systemctlPath == null) return false;

    try {
      final result = await _commandRunner(systemctlPath, [
        'is-active',
        '--quiet',
        unit,
      ]);
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  String? _resolveHelperPath() {
    final executableDirectory = p.dirname(_executablePath);
    return _resolveExecutable([
      p.join(executableDirectory, 'lifeos_firewall_helper'),
      '/opt/lifeos-anywhere/lifeos_firewall_helper',
    ]);
  }

  String? _resolveExecutable(List<String> candidates) {
    for (final candidate in candidates) {
      if (_pathExists(candidate)) return candidate;
    }
    return null;
  }
}
