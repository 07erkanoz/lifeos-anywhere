import 'dart:io';

import 'package:anyware/features/platform/linux/linux_firewall_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const executablePath = '/bundle/lifeos_anywhere';
  const helperPath = '/bundle/lifeos_firewall_helper';
  const pkexecPath = '/usr/bin/pkexec';
  const systemctlPath = '/usr/bin/systemctl';
  const ufwPath = '/usr/bin/ufw';

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('does nothing outside Linux', () async {
    final prefs = await SharedPreferences.getInstance();
    final service = LinuxFirewallService(prefs, isLinux: false);

    final check = await service.inspect();

    expect(check.state, LinuxFirewallState.notRequired);
  });

  test('requests authorization once when UFW is active', () async {
    final prefs = await SharedPreferences.getInstance();
    final service = LinuxFirewallService(
      prefs,
      isLinux: true,
      executablePath: executablePath,
      pathExists: (path) =>
          {helperPath, pkexecPath, systemctlPath, ufwPath}.contains(path),
      commandRunner: (executable, arguments) async {
        expect(executable, systemctlPath);
        expect(arguments, ['is-active', '--quiet', 'ufw']);
        return ProcessResult(1, 0, '', '');
      },
    );

    final check = await service.inspect();

    expect(check.state, LinuxFirewallState.needsAuthorization);
    expect(check.backend, LinuxFirewallBackend.ufw);
    expect(check.helperPath, helperPath);
    expect(check.pkexecPath, pkexecPath);
  });

  test('successful setup invokes fixed helper and persists result', () async {
    final prefs = await SharedPreferences.getInstance();
    final invocations = <(String, List<String>)>[];
    final service = LinuxFirewallService(
      prefs,
      isLinux: true,
      executablePath: executablePath,
      pathExists: (path) =>
          {helperPath, pkexecPath, systemctlPath, ufwPath}.contains(path),
      commandRunner: (executable, arguments) async {
        invocations.add((executable, arguments));
        return ProcessResult(1, 0, '', '');
      },
    );
    final check = await service.inspect();

    final result = await service.configure(check);
    final nextCheck = await service.inspect();

    expect(result.success, isTrue);
    final privilegedInvocation = invocations.firstWhere(
      (invocation) => invocation.$1 == pkexecPath,
    );
    expect(privilegedInvocation.$2, [helperPath, 'configure', 'ufw']);
    expect(nextCheck.state, LinuxFirewallState.configured);
  });

  test('declined prompt is deferred instead of shown every launch', () async {
    final now = DateTime(2026, 9, 3, 12);
    final prefs = await SharedPreferences.getInstance();
    final service = LinuxFirewallService(
      prefs,
      isLinux: true,
      executablePath: executablePath,
      now: () => now,
      pathExists: (path) =>
          {helperPath, pkexecPath, systemctlPath, ufwPath}.contains(path),
      commandRunner: (_, _) async => ProcessResult(1, 0, '', ''),
    );

    await service.deferPrompt();
    final check = await service.inspect();

    expect(check.state, LinuxFirewallState.deferred);
  });
}
