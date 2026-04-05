import 'dart:async';
import 'dart:io';

import 'package:anyware/core/constants.dart';
import 'package:anyware/core/logger.dart';
import 'package:anyware/features/discovery/data/discovery_service.dart';
import 'package:anyware/features/discovery/data/latency_service.dart';
import 'package:anyware/features/discovery/domain/device.dart';
import 'package:anyware/core/android_platform_service.dart';
import 'package:anyware/features/platform/android/direct_share_service.dart';
import 'package:anyware/features/settings/data/settings_repository.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

/// Provides the [Device] representing the current machine.
///
/// The device id is generated once (UUID v4), the name comes from
/// [SettingsRepository.getDeviceName], and the platform / version are
/// resolved from the running OS.
final localDeviceProvider = FutureProvider<Device>((ref) async {
  final settingsRepo = ref.watch(settingsRepositoryProvider);
  final deviceName = await settingsRepo.getDeviceName();
  final prefs = await SharedPreferences.getInstance();

  final platform = _resolvePlatform();

  // Persist device ID across restarts so other devices recognize us.
  var id = prefs.getString('device_id');
  if (id == null || id.isEmpty) {
    id = const Uuid().v4();
    await prefs.setString('device_id', id);
  }

  final ip = await _getBestLocalIp();
  AppLogger('LocalDevice').info('Selected IP = $ip, ID = $id');

  return Device(
    id: id,
    name: deviceName,
    ip: ip,
    port: AppConstants.defaultPort,
    platform: platform,
    version: AppConstants.protocolVersion,
    lastSeen: DateTime.now(),
  );
});

/// Picks the best local LAN IP address.
///
/// Strategy:
///   1. Try [NetworkInfo.getWifiIP] (works well on Android/iOS).
///   2. Enumerate interfaces and prefer one with a default gateway
///      (i.e. a "real" LAN adapter, not Hyper-V / VMware / VPN).
///   3. Fall back to the first non-loopback IPv4.
Future<String> _getBestLocalIp() async {
  // 1. Try WiFi IP first (especially good on mobile).
  //    Skip on Windows/Linux/macOS — NetworkInfo can return virtual adapter IPs.
  if (Platform.isAndroid || Platform.isIOS) {
    try {
      final info = NetworkInfo();
      final wifiIp = await info.getWifiIP();
      if (wifiIp != null && wifiIp.isNotEmpty) {
        return wifiIp;
      }
    } catch (_) {}
  }

  // 2. Enumerate interfaces. Prefer addresses in common private LAN ranges
  //    that are NOT virtual adapters (Hyper-V 172.x, VMware 192.168.224.x).
  try {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
    );

    String? fallback;

    for (final iface in interfaces) {
      final name = iface.name.toLowerCase();
      // Skip known virtual adapters (Windows + Linux).
      final isVirtual = name.contains('vmware') ||
          name.contains('hyper-v') ||
          name.contains('vethernet') ||
          name.contains('virtualbox') ||
          name.contains('docker') ||
          name.contains('wsl') ||
          name.contains('virbr') ||
          name.contains('veth') ||
          name.startsWith('br-') ||
          name.startsWith('tun') ||
          name.startsWith('tap') ||
          name.contains('lxc') ||
          name.contains('lxd');

      for (final addr in iface.addresses) {
        if (addr.isLoopback) continue;

        final ip = addr.address;

        // Save as fallback regardless.
        fallback ??= ip;

        if (isVirtual) continue;

        // Prefer 192.168.x.x or 10.x.x.x (common LAN ranges).
        if (ip.startsWith('192.168.') || ip.startsWith('10.')) {
          return ip;
        }
      }
    }

    // No ideal match — try any non-virtual, non-loopback.
    for (final iface in interfaces) {
      final name = iface.name.toLowerCase();
      final isVirtual = name.contains('vmware') ||
          name.contains('hyper-v') ||
          name.contains('vethernet') ||
          name.contains('virtualbox') ||
          name.contains('docker') ||
          name.contains('wsl') ||
          name.contains('virbr') ||
          name.contains('veth') ||
          name.startsWith('br-') ||
          name.startsWith('tun') ||
          name.startsWith('tap') ||
          name.contains('lxc') ||
          name.contains('lxd');
      if (isVirtual) continue;

      for (final addr in iface.addresses) {
        if (!addr.isLoopback) return addr.address;
      }
    }

    if (fallback != null) return fallback;
  } catch (_) {}

  return '';
}

/// Provides a managed [DiscoveryService] instance that is fully started.
///
/// The service is created and started asynchronously (socket bind + multicast
/// join), then returned. It lives for the entire app lifetime.
///
/// Automatically restarts when network connectivity changes (e.g. switching
/// from WiFi to Ethernet, or reconnecting after a disconnection).
final discoveryServiceProvider = FutureProvider<DiscoveryService>((ref) async {
  final device = await ref.watch(localDeviceProvider.future);

  final service = DiscoveryService(localDevice: device);

  // Await start so the socket is bound and multicast is joined before
  // anyone tries to read the stream.
  try {
    await service.start();
  } catch (e) {
    AppLogger('DiscoveryProvider').error('Failed to start discovery service', error: e);
  }

  // Monitor network connectivity changes and restart discovery automatically.
  StreamSubscription<List<ConnectivityResult>>? connectivitySub;
  try {
    connectivitySub = Connectivity().onConnectivityChanged.listen(
      (results) async {
        try {
          final hasNetwork = results.any(
            (r) =>
                r == ConnectivityResult.wifi ||
                r == ConnectivityResult.ethernet ||
                r == ConnectivityResult.mobile,
          );

          if (hasNetwork && service.isRunning) {
            // Only restart if IP actually changed — connectivity_plus fires
            // very frequently on Android and restarting clears all devices.
            final newIp = await _getBestLocalIp();
            if (newIp.isEmpty || newIp == service.localDevice.ip) return;

            AppLogger('DiscoveryProvider').info(
                'IP changed: ${service.localDevice.ip} → $newIp, restarting...');
            service.localDevice = service.localDevice.copyWith(ip: newIp);
            service.clearDevices();
            service.stop();

            // Re-acquire multicast lock — switching networks can invalidate it.
            if (Platform.isAndroid) {
              await AndroidPlatformService.instance.releaseMulticastLock();
              await AndroidPlatformService.instance.acquireMulticastLock();
            }

            await Future<void>.delayed(const Duration(seconds: 1));
            await service.start();
            AppLogger('DiscoveryProvider').info('Discovery restarted successfully.');
          } else if (hasNetwork && !service.isRunning) {
            // Network came back after being lost — start discovery.
            AppLogger('DiscoveryProvider').info('Network restored, starting discovery...');

            final newIp = await _getBestLocalIp();
            if (newIp.isNotEmpty) {
              service.localDevice = service.localDevice.copyWith(ip: newIp);
            }

            // Re-acquire multicast lock after network restore.
            if (Platform.isAndroid) {
              await AndroidPlatformService.instance.releaseMulticastLock();
              await AndroidPlatformService.instance.acquireMulticastLock();
            }

            await service.start();
            AppLogger('DiscoveryProvider').info('Discovery started after network restore.');
          } else if (!hasNetwork) {
            AppLogger('DiscoveryProvider').warning('Network lost, stopping discovery.');
            service.stop();
            // Clear the device list immediately so UI shows no devices.
            service.clearDevices();
          }
        } catch (e) {
          AppLogger('DiscoveryProvider').error('Network change handling error', error: e);
        }
      },
    );
  } catch (e) {
    AppLogger('DiscoveryProvider').error('Could not monitor connectivity', error: e);
  }

  // Periodic IP change detection — connectivity_plus misses WiFi→WiFi switches
  // (e.g. work WiFi → home WiFi). Poll every 10 s and restart if IP changed.
  Timer? ipPollTimer;
  ipPollTimer = Timer.periodic(const Duration(seconds: 10), (_) async {
    if (!service.isRunning) return;
    try {
      final currentIp = await _getBestLocalIp();
      if (currentIp.isNotEmpty && currentIp != service.localDevice.ip) {
        AppLogger('DiscoveryProvider')
            .info('IP changed: ${service.localDevice.ip} → $currentIp');
        service.localDevice = service.localDevice.copyWith(ip: currentIp);
        service.clearDevices();
        service.stop();

        if (Platform.isAndroid) {
          await AndroidPlatformService.instance.releaseMulticastLock();
          await AndroidPlatformService.instance.acquireMulticastLock();
        }

        await Future<void>.delayed(const Duration(seconds: 1));
        await service.start();
        AppLogger('DiscoveryProvider').info('Discovery restarted after IP change.');
      }
    } catch (e) {
      AppLogger('DiscoveryProvider').warning('IP poll check failed: $e');
    }
  });

  ref.onDispose(() {
    ipPollTimer?.cancel();
    connectivitySub?.cancel();
    service.dispose();
  });

  return service;
});

/// A broadcast [Stream] of discovered devices on the local network.
///
/// Emits a new list each time a device is added, updated, or removed.
/// Lives for the entire app lifetime so discovery is never interrupted.
final devicesProvider = StreamProvider<List<Device>>((ref) async* {
  // Wait for the discovery service to be fully started.
  final service = await ref.watch(discoveryServiceProvider.future);
  final localDevice = await ref.watch(localDeviceProvider.future);

  // Filter out our own device from the discovered list (by stable ID,
  // not IP — IP can change when switching networks).
  List<Device> filterSelf(List<Device> devices) {
    return devices.where((d) => d.id != localDevice.id).toList();
  }

  // Emit the current snapshot first (may be empty).
  yield filterSelf(service.devices);

  // Then forward all future updates.
  await for (final devices in service.devicesStream) {
    yield filterSelf(devices);
  }
});

/// Provides a method to manually restart the discovery service.
///
/// Used by the refresh button in the UI. Calling this stops the current
/// service, clears stale data, re-resolves the local IP, and restarts.
final refreshDiscoveryProvider = Provider<Future<void> Function()>((ref) {
  return () async {
    try {
      final service = await ref.read(discoveryServiceProvider.future);

      AppLogger('DiscoveryProvider').info('Manual refresh triggered.');

      // Update local IP in case the network changed.
      final newIp = await _getBestLocalIp();
      if (newIp.isNotEmpty) {
        service.localDevice = service.localDevice.copyWith(ip: newIp);
      }

      // Full restart: stop → delay → start.
      service.stop();
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await service.start();

      AppLogger('DiscoveryProvider').info('Manual refresh completed.');
    } catch (e) {
      AppLogger('DiscoveryProvider').error('Manual refresh failed', error: e);
    }
  };
});

// ---------------------------------------------------------------------------
// Network diagnostics
// ---------------------------------------------------------------------------

/// Diagnostic issue detected on the network.
enum NetworkIssue {
  /// No Wi-Fi or Ethernet connection detected.
  noNetwork,

  /// Virtual adapters detected that might interfere with multicast.
  virtualAdapters,
}

/// Result of a network diagnostics check.
class NetworkDiagnostics {
  const NetworkDiagnostics({
    required this.issues,
    this.virtualAdapterNames = const [],
  });

  final List<NetworkIssue> issues;
  final List<String> virtualAdapterNames;

  bool get hasIssues => issues.isNotEmpty;
}

/// Runs lightweight network diagnostics to detect issues that might prevent
/// device discovery from working.
final networkDiagnosticsProvider = FutureProvider<NetworkDiagnostics>((ref) async {
  final issues = <NetworkIssue>[];
  final virtualNames = <String>[];

  // 1. Check network connectivity.
  try {
    final results = await Connectivity().checkConnectivity();
    final hasNetwork = results.any(
      (r) =>
          r == ConnectivityResult.wifi ||
          r == ConnectivityResult.ethernet ||
          r == ConnectivityResult.mobile,
    );
    if (!hasNetwork) {
      issues.add(NetworkIssue.noNetwork);
    }
  } catch (_) {}

  // 2. Check for virtual adapters (Windows/Linux/macOS).
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
      );
      for (final iface in interfaces) {
        final name = iface.name.toLowerCase();
        final isVirtual = name.contains('vmware') ||
            name.contains('hyper-v') ||
            name.contains('vethernet') ||
            name.contains('virtualbox') ||
            name.contains('docker') ||
            name.contains('wsl') ||
            name.contains('virbr') ||
            name.contains('veth') ||
            name.startsWith('br-') ||
            name.startsWith('tun') ||
            name.startsWith('tap') ||
            name.contains('lxc') ||
            name.contains('lxd');
        if (isVirtual) {
          virtualNames.add(iface.name);
        }
      }
      if (virtualNames.isNotEmpty) {
        issues.add(NetworkIssue.virtualAdapters);
      }
    } catch (_) {}
  }

  return NetworkDiagnostics(
    issues: issues,
    virtualAdapterNames: virtualNames,
  );
});

// ---------------------------------------------------------------------------
// Latency monitoring
// ---------------------------------------------------------------------------

/// Provides a [LatencyService] that periodically pings discovered devices.
///
/// Updates the device list whenever [devicesProvider] changes, and emits
/// latency measurements every 10 seconds.
final latencyServiceProvider = Provider<LatencyService>((ref) {
  final service = LatencyService();

  // Listen to device list changes and update the service.
  ref.listen<AsyncValue<List<Device>>>(devicesProvider, (_, next) {
    next.whenData((devices) {
      service.updateDevices(devices);
    });
  }, fireImmediately: true);

  service.startDynamic();

  ref.onDispose(() {
    service.dispose();
  });

  return service;
});

/// Provides a stream of latency measurements (device id → ms).
///
/// UI widgets can watch this to show real-time ping indicators.
final latencyUpdatesProvider = StreamProvider<Map<String, int>>((ref) {
  final service = ref.watch(latencyServiceProvider);
  return service.latencyUpdates;
});

// ---------------------------------------------------------------------------
// Android Direct Share
// ---------------------------------------------------------------------------

/// Provides a [DirectShareService] that pushes discovered devices as
/// share shortcuts to the Android system.
///
/// Automatically updates shortcuts whenever the device list changes.
/// No-op on non-Android platforms.
final directShareProvider = Provider<DirectShareService>((ref) {
  final service = DirectShareService();

  if (Platform.isAndroid) {
    ref.listen<AsyncValue<List<Device>>>(devicesProvider, (_, next) {
      next.whenData((devices) {
        service.updateTargets(devices);
      });
    }, fireImmediately: true);

    ref.onDispose(() {
      service.clearTargets();
    });
  }

  return service;
});

/// Resolves the current platform to a short string identifier used in the
/// discovery protocol (e.g. `"windows"`, `"android"`, `"ios"`, `"linux"`).
String _resolvePlatform() {
  if (Platform.isWindows) return 'windows';
  if (Platform.isAndroid) return 'android';
  if (Platform.isIOS) return 'ios';
  if (Platform.isLinux) return 'linux';
  if (Platform.isMacOS) return 'macos';
  return 'unknown';
}
