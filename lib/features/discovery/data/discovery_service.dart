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
class DiscoveryService {
  DiscoveryService({required this.localDevice});

  static final _log = AppLogger('Discovery');

  /// The device info representing this machine.
  Device localDevice;

  RawDatagramSocket? _socket;
  Timer? _broadcastTimer;
  Timer? _cleanupTimer;

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

    // Listen for incoming datagrams.
    _socket!.listen(
      (RawSocketEvent event) {
        if (event == RawSocketEvent.read) {
          _handleIncoming();
        }
      },
      onError: (Object error) {
        _log.error('Socket error', error: error);
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
  }

  /// Stops the discovery service without disposing streams.
  ///
  /// The service can be restarted via [start] after stopping.
  void stop() {
    _broadcastTimer?.cancel();
    _broadcastTimer = null;

    _cleanupTimer?.cancel();
    _cleanupTimer = null;

    try {
      _socket?.close();
    } catch (_) {
      // Ignore close errors.
    }
    _socket = null;
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

  /// Sends a single UDP multicast datagram containing the local device JSON.
  ///
  /// Broadcasts to both the multicast group AND the subnet broadcast address
  /// (255.255.255.255) for maximum compatibility. Some network configurations
  /// and firewalls block multicast but allow broadcast.
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
    } catch (e) {
      _log.warning('Broadcast failed', error: e);
    }
  }

  /// Reads all available datagrams from the socket and processes them.
  void _handleIncoming() {
    if (_socket == null) return;

    Datagram? datagram = _socket!.receive();
    while (datagram != null) {
      _processPacket(datagram);
      datagram = _socket!.receive();
    }
  }

  /// Parses a single datagram into a [Device] and updates the discovered map.
  void _processPacket(Datagram datagram) {
    try {
      final jsonString = utf8.decode(datagram.data);
      final json = jsonDecode(jsonString) as Map<String, dynamic>;
      final device = Device.fromJson(json);

      _log.debug('Received packet from ${datagram.address.address} - device: ${device.name} (${device.id})');

      // Ignore our own broadcasts.
      if (device.id == localDevice.id) {
        _log.debug('Ignoring own broadcast.');
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
