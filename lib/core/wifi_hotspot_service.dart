import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';

import 'package:anyware/core/logger.dart';

final _log = AppLogger('WifiHotspot');

/// Information about an active WiFi hotspot.
class HotspotInfo {
  final String ssid;
  final String password;
  final String ip;

  const HotspotInfo({
    required this.ssid,
    required this.password,
    required this.ip,
  });
}

/// Platform-agnostic WiFi hotspot service.
///
/// - **Android**: Uses native `WifiManager.startLocalOnlyHotspot()` via
///   platform channel.
/// - **Windows**: Uses `netsh` commands via `Process.run()`.
/// - **Linux**: Uses `nmcli` via `Process.run()`.
/// - **iOS / macOS**: Not supported (Apple doesn't expose hotspot APIs).
class WifiHotspotService {
  WifiHotspotService._();

  static final WifiHotspotService instance = WifiHotspotService._();

  static const _channel = MethodChannel('com.lifeos.anyware/platform');

  bool _isActive = false;

  /// Whether this platform can create a WiFi hotspot.
  bool get canCreateHotspot =>
      Platform.isAndroid || Platform.isWindows || Platform.isLinux;

  /// Whether a hotspot is currently active.
  bool get isActive => _isActive;

  /// Start a WiFi hotspot. Returns [HotspotInfo] on success, `null` on failure.
  Future<HotspotInfo?> startHotspot() async {
    if (_isActive) {
      _log.warning('Hotspot already active');
      return null;
    }

    try {
      if (Platform.isAndroid) {
        return await _startAndroidHotspot();
      } else if (Platform.isWindows) {
        return await _startWindowsHotspot();
      } else if (Platform.isLinux) {
        return await _startLinuxHotspot();
      } else {
        _log.warning('Hotspot not supported on ${Platform.operatingSystem}');
        return null;
      }
    } catch (e) {
      _log.error('Failed to start hotspot: $e', error: e);
      return null;
    }
  }

  /// Stop the active hotspot.
  Future<void> stopHotspot() async {
    if (!_isActive) return;

    try {
      if (Platform.isAndroid) {
        await _channel.invokeMethod('stopHotspot');
      } else if (Platform.isWindows) {
        await _stopWindowsHotspot();
      } else if (Platform.isLinux) {
        // nmcli automatically cleans up, but we can deactivate
        await Process.run('nmcli', ['connection', 'down', 'Hotspot']);
      }
      _isActive = false;
      _log.info('Hotspot stopped');
    } catch (e) {
      _log.warning('Failed to stop hotspot: $e');
      _isActive = false;
    }
  }

  // ────────────────────────────────────────────────────────────────────────
  // Android
  // ────────────────────────────────────────────────────────────────────────

  Future<HotspotInfo?> _startAndroidHotspot() async {
    final result = await _channel.invokeMethod<Map>('startHotspot');
    if (result == null) return null;

    _isActive = true;
    final info = HotspotInfo(
      ssid: result['ssid'] as String? ?? 'LifeOS-Hotspot',
      password: result['password'] as String? ?? '',
      ip: result['ip'] as String? ?? '192.168.43.1',
    );
    _log.info('Android hotspot started: SSID=${info.ssid}');
    return info;
  }

  // ────────────────────────────────────────────────────────────────────────
  // Windows  (Mobile Hotspot via WinRT TetheringManager API)
  // ────────────────────────────────────────────────────────────────────────

  Future<HotspotInfo?> _startWindowsHotspot() async {
    final ssid = _generateSsid();
    final password = _generatePassword();

    // Single PowerShell script that:
    //  1. Loads WinRT types
    //  2. Configures SSID + password
    //  3. Starts the Mobile Hotspot
    //  4. Outputs SSID|PASSWORD|IP as a parseable line
    final psScript = r'''
Add-Type -AssemblyName System.Runtime.WindowsRuntime

$asTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() |
  Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
  $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]

Function Await($WinRtTask, $ResultType) {
  $asTask = $asTaskGeneric.MakeGenericMethod($ResultType)
  $netTask = $asTask.Invoke($null, @($WinRtTask))
  $netTask.Wait(-1) | Out-Null
  $netTask.Result
}

Function AwaitAction($WinRtTask) {
  $asTask = ([System.WindowsRuntimeSystemExtensions].GetMethods() |
    Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
    !$_.IsGenericMethod })[0]
  $netTask = $asTask.Invoke($null, @($WinRtTask))
  $netTask.Wait(-1) | Out-Null
}

# Activate WinRT types
[Windows.Networking.Connectivity.NetworkInformation,Windows.Networking.Connectivity,ContentType=WindowsRuntime] | Out-Null

$connProfile = [Windows.Networking.Connectivity.NetworkInformation]::GetInternetConnectionProfile()
if ($connProfile -eq $null) {
  Write-Error "NO_INTERNET"
  exit 1
}

$tethManager = [Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager,Windows.Networking.NetworkOperators,ContentType=WindowsRuntime]::CreateFromConnectionProfile($connProfile)

# Configure custom SSID and password
$apConfig = $tethManager.GetCurrentAccessPointConfiguration()
$apConfig.Ssid = "''' +
        ssid +
        r'''"
$apConfig.Passphrase = "''' +
        password +
        r'''"

try {
  AwaitAction ($tethManager.ConfigureAccessPointAsync($apConfig))
} catch {
  # ConfigureAccessPoint may fail on some machines; continue with existing config
}

# Re-read config to get actual values
$apConfig = $tethManager.GetCurrentAccessPointConfiguration()
$actualSsid = $apConfig.Ssid
$actualPass = $apConfig.Passphrase

# Start the hotspot
$result = Await ($tethManager.StartTetheringAsync()) ([Windows.Networking.NetworkOperators.NetworkOperatorTetheringOperationResult])

if ($result.Status -ne 0) {
  Write-Error ("START_FAILED:" + $result.Status.ToString() + ":" + $result.AdditionalErrorMessage)
  exit 1
}

# Find the hotspot IP (usually 192.168.137.1)
$hotspotIp = "192.168.137.1"
$ifaces = [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()
foreach ($iface in $ifaces) {
  if ($iface.Description -match 'Microsoft Wi-Fi Direct Virtual' -or
      $iface.Description -match 'Mobile Hotspot' -or
      $iface.Name -match 'Local Area Connection\*') {
    $props = $iface.GetIPProperties()
    foreach ($addr in $props.UnicastAddresses) {
      if ($addr.Address.AddressFamily -eq 'InterNetwork') {
        $hotspotIp = $addr.Address.ToString()
        break
      }
    }
  }
}

Write-Output ("OK|" + $actualSsid + "|" + $actualPass + "|" + $hotspotIp)
''';

    final result = await Process.run(
      'powershell',
      ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', psScript],
    );

    final stdout = (result.stdout as String? ?? '').trim();
    final stderr = (result.stderr as String? ?? '').trim();

    _log.info('Windows hotspot PS stdout: $stdout');
    if (stderr.isNotEmpty) {
      _log.warning('Windows hotspot PS stderr: $stderr');
    }

    if (result.exitCode != 0 || !stdout.startsWith('OK|')) {
      _log.warning('Failed to start Windows hotspot: exit=${result.exitCode}');
      return null;
    }

    // Parse "OK|SSID|PASSWORD|IP"
    final parts = stdout.split('|');
    if (parts.length < 4) {
      _log.warning('Unexpected PS output: $stdout');
      return null;
    }

    final actualSsid = parts[1];
    final actualPassword = parts[2];
    final ip = parts[3];

    _isActive = true;
    final info = HotspotInfo(ssid: actualSsid, password: actualPassword, ip: ip);
    _log.info('Windows Mobile Hotspot started: SSID=$actualSsid, IP=$ip');
    return info;
  }

  Future<void> _stopWindowsHotspot() async {
    const psScript = r'''
Add-Type -AssemblyName System.Runtime.WindowsRuntime

$asTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() |
  Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
  $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]

Function Await($WinRtTask, $ResultType) {
  $asTask = $asTaskGeneric.MakeGenericMethod($ResultType)
  $netTask = $asTask.Invoke($null, @($WinRtTask))
  $netTask.Wait(-1) | Out-Null
  $netTask.Result
}

[Windows.Networking.Connectivity.NetworkInformation,Windows.Networking.Connectivity,ContentType=WindowsRuntime] | Out-Null

$connProfile = [Windows.Networking.Connectivity.NetworkInformation]::GetInternetConnectionProfile()
if ($connProfile -ne $null) {
  $tethManager = [Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager,Windows.Networking.NetworkOperators,ContentType=WindowsRuntime]::CreateFromConnectionProfile($connProfile)
  Await ($tethManager.StopTetheringAsync()) ([Windows.Networking.NetworkOperators.NetworkOperatorTetheringOperationResult])
}
''';

    await Process.run(
      'powershell',
      ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', psScript],
    );
  }

  // ────────────────────────────────────────────────────────────────────────
  // Linux
  // ────────────────────────────────────────────────────────────────────────

  Future<HotspotInfo?> _startLinuxHotspot() async {
    final ssid = _generateSsid();
    final password = _generatePassword();

    // Find WiFi interface
    final ifResult = await Process.run('nmcli', [
      '-t', '-f', 'DEVICE,TYPE', 'device', 'status',
    ]);
    String? wifiIface;
    for (final line in (ifResult.stdout as String).split('\n')) {
      if (line.contains(':wifi')) {
        wifiIface = line.split(':').first;
        break;
      }
    }

    if (wifiIface == null) {
      _log.warning('No WiFi interface found');
      return null;
    }

    final result = await Process.run('nmcli', [
      'd', 'wifi', 'hotspot',
      'ifname', wifiIface,
      'ssid', ssid,
      'password', password,
    ]);

    if (result.exitCode != 0) {
      _log.warning('Failed to start hotspot: ${result.stderr}');
      return null;
    }

    // Get IP (usually 10.42.0.1 for nmcli hotspot)
    final ip = await _getLinuxHotspotIp(wifiIface) ?? '10.42.0.1';

    _isActive = true;
    final info = HotspotInfo(ssid: ssid, password: password, ip: ip);
    _log.info('Linux hotspot started: SSID=$ssid, IP=$ip');
    return info;
  }

  Future<String?> _getLinuxHotspotIp(String iface) async {
    try {
      final interfaces = await NetworkInterface.list();
      for (final netIface in interfaces) {
        if (netIface.name == iface) {
          for (final addr in netIface.addresses) {
            if (addr.type == InternetAddressType.IPv4 && !addr.isLoopback) {
              return addr.address;
            }
          }
        }
      }
    } catch (_) {}
    return null;
  }

  // ────────────────────────────────────────────────────────────────────────
  // Helpers
  // ────────────────────────────────────────────────────────────────────────

  String _generateSsid() {
    final rng = Random();
    final suffix = rng.nextInt(9000) + 1000;
    return 'LifeOS-$suffix';
  }

  String _generatePassword() {
    const chars = 'abcdefghijkmnpqrstuvwxyzABCDEFGHJKMNPQRSTUVWXYZ23456789';
    final rng = Random.secure();
    return List.generate(8, (_) => chars[rng.nextInt(chars.length)]).join();
  }
}
