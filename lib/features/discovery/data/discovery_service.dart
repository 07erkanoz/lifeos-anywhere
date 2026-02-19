import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:anyware/core/constants.dart';
import 'package:anyware/core/logger.dart';
import 'package:anyware/features/discovery/domain/device.dart';
import 'package:network_info_plus/network_info_plus.dart';

/// Service that handles UDP multicast device discovery on the local network.
///
/// Broadcasts the current device's info as JSON on the multicast group
/// [AppConstants.multicastGroup]:[AppConstants.discoveryPort] every
/// [AppConstants.discoveryIntervalSeconds] seconds and listens for other
/// devices doing the same. Devices that have not been seen for
/// [AppConstants.deviceTimeoutSeconds] are automatically removed.
///
/// Includes automatic recovery mechanisms:
/// - Periodic multicast group re-join (every 2 minutes) to counter OS/router
///   silently dropping the membership.
/// - Consecutive broadcast failure tracking: if 3+ broadcasts fail in a row
///   the socket is assumed dead and the entire service restarts.
/// - Socket error listener triggers automatic restart.
/// - Periodic health checks verify the socket is still functional.
class DiscoveryService {
  DiscoveryService({required this.localDevice});

  static final _log = AppLogger('Discovery');

  /// The device info representing this machine.
  Device localDevice;

  RawDatagramSocket? _socket;
  Timer? _broadcastTimer;
  Timer? _cleanupTimer;
  Timer? _rejoinTimer;
  Timer? _healthCheckTimer;

  /// Consecutive broadcast failures. Reset on every successful send.
  int _consecutiveBroadcastFailures = 0;

  /// Maximum consecutive failures before triggering a full restart.
  static const int _maxConsecutiveFailures = 3;

  /// Whether an automatic restart is currently in progress (prevents re-entry).
  bool _isRestarting = false;

  /// Timestamp of the last successfully received packet. Used by the health
  /// check to detect "silent death" scenarios where the socket stops
  /// delivering packets but doesn't report an error.
  DateTime _lastPacketReceived = DateTime.now();

  /// All currently discovered remote devices, keyed by their [Device.id].
  final Map<String, Device> _devices = {};

  final StreamController<List<Device>> _devicesController =
      StreamController<List<Device>>.broadcast();

  /// A broadcast stream that emits the current list of discovered devices
  /// whenever the set changes (device added, updated, or removed).
  Stream<List<Device>> get devicesStream => _devicesController.stream;

  /// Returns the current snapshot of discovered devices.
  List<Device> get devices => _devices.values.toList();

  /// Whether the service is currently running.
  bool get isRunning => _socket != null;

  /// Starts the discovery service.
  ///
  /// 1. Resolves the local IP address using [NetworkInfo].
  /// 2. Binds a [RawDatagramSocket] to the discovery port.
  /// 3. Joins the multicast group.
  /// 4. Begins periodic broadcasting and listening.
  /// 5. Starts a cleanup timer to evict stale devices.
  /// 6. Starts a periodic multicast re-join timer.
  /// 7. Starts a health check timer.
  Future<void> start() async {
    if (_socket != null) return;

    _log.info('Starting... (device: ${localDevice.name}, id: ${localDevice.id})');

    // Resolve local IP so we can update localDevice and filter our own packets.
    final localIp = await _getLocalIp();
    _log.info('Local IP resolved: $localIp');
    if (localIp != null && localIp != localDevice.ip) {
      localDevice = localDevice.copyWith(ip: localIp);
    }

    final multicastAddress =
        InternetAddress(AppConstants.multicastGroup, type: InternetAddressType.IPv4);

    // Bind to the discovery port. On Windows we bind to anyIPv4; on other
    // platforms we bind to the multicast group address directly so that the
    // OS routes multicast traffic to this socket.
    final bindAddress =
        Platform.isWindows ? InternetAddress.anyIPv4 : multicastAddress;

    // On Windows, binding to a specific UDP port can fail with errno 10013
    // (WSAEACCES) if the Windows Firewall hasn't granted inbound access yet.
    // WindowsService._ensureFirewallRules() should have added the rules via
    // UAC before we get here. We retry a few times with a short delay to
    // allow the firewall rule to propagate.
    int boundPort = AppConstants.discoveryPort;

    const maxAttempts = 3;
    for (int attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        _socket = await RawDatagramSocket.bind(
          bindAddress,
          AppConstants.discoveryPort,
          reuseAddress: true,
          reusePort: !Platform.isWindows,
        );
        boundPort = AppConstants.discoveryPort;
        _log.info('Socket bound on port $boundPort');
        break;
      } catch (e) {
        _log.warning('Bind attempt $attempt/$maxAttempts failed', error: e);

        if (attempt < maxAttempts) {
          // Wait a bit for the firewall rule to take effect.
          await Future<void>.delayed(const Duration(seconds: 2));
        } else {
          _log.error('ALL bind attempts failed. Discovery will not receive packets.');
          rethrow;
        }
      }
    }

    // Allow loopback so two instances on the same machine can discover each
    // other (useful for testing and for running side-by-side on one PC).
    _socket!.multicastLoopback = true;
    _socket!.broadcastEnabled = true;

    // Join the multicast group on all suitable network interfaces so that
    // discovery works regardless of which adapter is connected to the LAN.
    await _joinMulticastOnAllInterfaces(multicastAddress, localIp);

    _log.info('Multicast joined. Listening on port $boundPort, broadcasting to ${AppConstants.discoveryPort}.');

    // Reset failure counters.
    _consecutiveBroadcastFailures = 0;
    _lastPacketReceived = DateTime.now();

    // Listen for incoming datagrams.
    _socket!.listen(
      (RawSocketEvent event) {
        if (event == RawSocketEvent.read) {
          _handleIncoming();
        }
      },
      onError: (Object error) {
        _log.error('Socket listen error — triggering restart', error: error);
        _scheduleRestart();
      },
      onDone: () {
        _log.warning('Socket stream closed unexpectedly — triggering restart');
        _socket = null;
        _scheduleRestart();
      },
    );

    // Broadcast our own info periodically.
    _broadcast();
    _broadcastTimer = Timer.periodic(
      Duration(seconds: AppConstants.discoveryIntervalSeconds),
      (_) => _broadcast(),
    );

    // Run the cleanup pass every 5 seconds to remove stale devices.
    _cleanupTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _cleanupStaleDevices(),
    );

    // Periodically re-join multicast group every 2 minutes.
    // Some OS/router combos silently drop the IGMP membership after a while.
    _rejoinTimer = Timer.periodic(
      const Duration(minutes: 2),
      (_) => _rejoinMulticast(),
    );

    // Health check every 30 seconds: if we're broadcasting but haven't
    // received ANY packet (including our own loopback) in 60 seconds,
    // the socket is probably dead.
    _healthCheckTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _healthCheck(),
    );
  }

  /// Stops the discovery service without disposing streams.
  ///
  /// The service can be restarted via [start] after stopping.
  void stop() {
    _broadcastTimer?.cancel();
    _broadcastTimer = null;

    _cleanupTimer?.cancel();
    _cleanupTimer = null;

    _rejoinTimer?.cancel();
    _rejoinTimer = null;

    _healthCheckTimer?.cancel();
    _healthCheckTimer = null;

    try {
      _socket?.close();
    } catch (_) {
      // Ignore close errors.
    }
    _socket = null;
  }

  /// Clears discovered devices and emits an empty list.
  ///
  /// Use this when the network is lost so the UI immediately reflects
  /// that no peers are reachable.
  void clearDevices() {
    if (_devices.isNotEmpty) {
      _devices.clear();
      _emitDevices();
    }
  }

  /// Stops the service and closes the stream controller permanently.
  void dispose() {
    stop();
    _devices.clear();
    _devicesController.close();
  }

  // ---------------------------------------------------------------------------
  // Private helpers
  // ---------------------------------------------------------------------------

  /// Joins the multicast group on every available IPv4 network interface.
  ///
  /// This ensures that devices on any connected LAN segment can be discovered.
  /// Errors for individual interfaces are silently ignored (the interface may
  /// not support multicast or may already be joined).
  Future<void> _joinMulticastOnAllInterfaces(
    InternetAddress multicastAddress,
    String? localIp,
  ) async {
    // 1. Always try a plain join first (works on most platforms).
    try {
      _socket!.joinMulticast(multicastAddress);
    } catch (_) {}

    // 2. Then try joining on each specific interface for better coverage.
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
      );
      for (final iface in interfaces) {
        try {
          _socket!.joinMulticast(multicastAddress, iface);
        } catch (_) {
          // Interface may not support multicast — skip.
        }
      }
    } catch (_) {
      // Could not enumerate interfaces — the plain join above should suffice.
    }
  }

  /// Re-joins the multicast group on all interfaces.
  ///
  /// Called periodically to counter OS/router silently dropping the IGMP
  /// membership. This is a common cause of "devices stop seeing each other
  /// after a while" on LAN networks.
  Future<void> _rejoinMulticast() async {
    if (_socket == null) return;

    _log.debug('Periodic multicast re-join...');
    final multicastAddress =
        InternetAddress(AppConstants.multicastGroup, type: InternetAddressType.IPv4);

    try {
      await _joinMulticastOnAllInterfaces(multicastAddress, localDevice.ip);
    } catch (e) {
      _log.warning('Multicast re-join failed', error: e);
    }
  }

  /// Performs a health check on the discovery socket.
  ///
  /// If we haven't received any packet (including our own loopback broadcasts)
  /// for more than 60 seconds while the service is supposedly running, the
  /// socket is assumed dead and we trigger a full restart.
  void _healthCheck() {
    if (_socket == null) return;

    final silentDuration = DateTime.now().difference(_lastPacketReceived);
    if (silentDuration.inSeconds > 60) {
      _log.warning(
        'Health check: no packets received for ${silentDuration.inSeconds}s '
        '— socket is likely dead, triggering restart.',
      );
      _scheduleRestart();
    }
  }

  /// Schedules an automatic restart of the discovery service.
  ///
  /// Guards against re-entry so multiple error paths don't trigger
  /// concurrent restarts.
  Future<void> _scheduleRestart() async {
    if (_isRestarting) return;
    _isRestarting = true;

    _log.info('Automatic restart scheduled...');

    try {
      stop();
      // Short delay to let the old socket release the port.
      await Future<void>.delayed(const Duration(seconds: 2));
      await start();
      _log.info('Automatic restart completed successfully.');
    } catch (e) {
      _log.error('Automatic restart failed', error: e);
      // Try again in 10 seconds.
      Future<void>.delayed(const Duration(seconds: 10), () {
        _isRestarting = false;
        _scheduleRestart();
      });
      return;
    }

    _isRestarting = false;
  }

  /// Sends a single UDP multicast datagram containing the local device JSON.
  ///
  /// Broadcasts to both the multicast group AND the subnet broadcast address
  /// (255.255.255.255) for maximum compatibility. Some network configurations
  /// and firewalls block multicast but allow broadcast.
  ///
  /// Tracks consecutive failures. If [_maxConsecutiveFailures] is reached,
  /// triggers a full socket restart.
  void _broadcast() {
    if (_socket == null) return;

    try {
      final data = utf8.encode(jsonEncode(localDevice.toJson()));

      // 1. Multicast
      _socket!.send(
        data,
        InternetAddress(AppConstants.multicastGroup),
        AppConstants.discoveryPort,
      );

      // 2. Subnet broadcast fallback (works even when multicast is blocked).
      _socket!.send(
        data,
        InternetAddress('255.255.255.255'),
        AppConstants.discoveryPort,
      );

      // Reset failure counter on success.
      _consecutiveBroadcastFailures = 0;
    } catch (e) {
      _consecutiveBroadcastFailures++;
      _log.warning(
        'Broadcast failed ($_consecutiveBroadcastFailures/$_maxConsecutiveFailures)',
        error: e,
      );

      if (_consecutiveBroadcastFailures >= _maxConsecutiveFailures) {
        _log.error('Too many consecutive broadcast failures — socket is dead, restarting.');
        _consecutiveBroadcastFailures = 0;
        _scheduleRestart();
      }
    }
  }

  /// Reads all available datagrams from the socket and processes them.
  void _handleIncoming() {
    if (_socket == null) return;

    try {
      Datagram? datagram = _socket!.receive();
      while (datagram != null) {
        _lastPacketReceived = DateTime.now();
        _processPacket(datagram);
        datagram = _socket!.receive();
      }
    } catch (e) {
      _log.error('Error reading from socket', error: e);
    }
  }

  /// Parses a single datagram into a [Device] and updates the discovered map.
  void _processPacket(Datagram datagram) {
    try {
      final jsonString = utf8.decode(datagram.data);
      final json = jsonDecode(jsonString) as Map<String, dynamic>;
      final device = Device.fromJson(json);

      // Ignore our own broadcasts.
      if (device.id == localDevice.id) {
        return;
      }

      // Update the IP to the actual source address if the device didn't set it.
      final updatedDevice = device.copyWith(
        ip: device.ip.isNotEmpty ? device.ip : datagram.address.address,
        lastSeen: DateTime.now(),
      );

      _devices[updatedDevice.id] = updatedDevice;

      // Always emit so UI stays in sync (lastSeen, name, ip changes, etc.).
      _emitDevices();
    } catch (_) {
      // Malformed packet — ignore.
    }
  }

  /// Adds a device manually (e.g., via QR code scan).
  void addManualDevice(Device device) {
    _log.info('Adding manual device: ${device.name} (${device.ip})');
    final updatedDevice = device.copyWith(lastSeen: DateTime.now());
    _devices[updatedDevice.id] = updatedDevice;
    _emitDevices();
  }

  /// Removes devices that have not been seen within the timeout window.
  void _cleanupStaleDevices() {
    final now = DateTime.now();
    final staleIds = <String>[];

    for (final entry in _devices.entries) {
      final elapsed = now.difference(entry.value.lastSeen).inSeconds;
      if (elapsed > AppConstants.deviceTimeoutSeconds) {
        staleIds.add(entry.key);
      }
    }

    if (staleIds.isNotEmpty) {
      for (final id in staleIds) {
        _devices.remove(id);
      }
      _emitDevices();
    }
  }

  /// Pushes the current device list to the stream.
  void _emitDevices() {
    if (!_devicesController.isClosed) {
      _devicesController.add(_devices.values.toList());
    }
  }

  /// Obtains the best local LAN IP address, skipping virtual adapters.
  ///
  /// On mobile uses [NetworkInfo.getWifiIP]. On desktop enumerates interfaces
  /// and prefers real LAN adapters (192.168.x.x / 10.x.x.x) over virtual
  /// ones (Hyper-V, VMware, Docker, WSL).
  Future<String?> _getLocalIp() async {
    // On mobile, WiFi IP is reliable.
    if (Platform.isAndroid || Platform.isIOS) {
      try {
        final info = NetworkInfo();
        final wifiIp = await info.getWifiIP();
        if (wifiIp != null && wifiIp.isNotEmpty) return wifiIp;
      } catch (_) {}
    }

    // Enumerate interfaces — prefer real LAN adapters.
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
      );

      String? fallback;

      for (final iface in interfaces) {
        final name = iface.name.toLowerCase();
        final isVirtual = name.contains('vmware') ||
            name.contains('hyper-v') ||
            name.contains('vethernet') ||
            name.contains('virtualbox') ||
            name.contains('docker') ||
            name.contains('wsl');

        for (final addr in iface.addresses) {
          if (addr.isLoopback) continue;
          fallback ??= addr.address;
          if (isVirtual) continue;
          if (addr.address.startsWith('192.168.') ||
              addr.address.startsWith('10.')) {
            return addr.address;
          }
        }
      }

      // Any non-virtual, non-loopback.
      for (final iface in interfaces) {
        final name = iface.name.toLowerCase();
        final isVirtual = name.contains('vmware') ||
            name.contains('hyper-v') ||
            name.contains('vethernet') ||
            name.contains('virtualbox') ||
            name.contains('docker') ||
            name.contains('wsl');
        if (isVirtual) continue;
        for (final addr in iface.addresses) {
          if (!addr.isLoopback) return addr.address;
        }
      }

      return fallback;
    } catch (_) {}

    return null;
  }
}
