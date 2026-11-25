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
  StreamSubscription<RawSocketEvent>? _socketSub;

  /// Dedicated send socket on Windows, bound to the real LAN IP so outbound
  /// packets go through the physical adapter instead of a virtual one
  /// (Hyper-V, WSL). Null on non-Windows or if creation failed.
  RawDatagramSocket? _sendSocket;

  Timer? _broadcastTimer;
  Timer? _cleanupTimer;
  Timer? _rejoinTimer;
  Timer? _healthCheckTimer;
  Timer? _probeTimer;

  /// Paired devices (id, last address) to look for even when none of their
  /// broadcasts arrives. Set by the provider from the trust store.
  List<({String id, String ip})> Function()? knownPeers;

  /// A device silent for this long is asked over HTTP (GET /api/info) whether
  /// it is still there. Android Wi-Fi drops broadcasts in power save and a
  /// firewall may drop them on the other side, while the device's own server
  /// still answers: it stays listed instead of blinking out (LifeOS does the
  /// same, lifeos_store/yakin.py `_probe`).
  int get _probeAfterSeconds => _quiet ? 75 : 8;
  bool _probing = false;

  /// Quiet: the app is in the background, kept reachable by the battery-light
  /// service (BackgroundTransferService.presence). One announcement and one
  /// look at silent paired devices every [quietIntervalSeconds], no
  /// multicast lock, no restart for silence (broadcasts are not received
  /// then): the phone wakes for little more than a peer's unicast packet or a
  /// connection to its server. LifeOS writes to phones as rarely
  /// (lifeos_store/yakin.py `MOBILE_EVERY`).
  bool _quiet = false;
  bool get quiet => _quiet;
  static const int quietIntervalSeconds = 30;

  /// In a device's announcement: it is a phone in the background (quiet
  /// mode). Without a wake lock its announcements stop while it sleeps,
  /// though it still wakes for a packet sent to it.
  static const String quietCapability = 'sessiz';

  /// How long a quiet device stays listed without being heard (probes keep
  /// it while it answers).
  static const int quietDeviceTimeoutSeconds = 15 * 60;

  static bool _isQuiet(Device d) => d.capabilities.contains(quietCapability);

  int get _broadcastSeconds => _quiet
      ? quietIntervalSeconds
      : Platform.isAndroid
      ? AppConstants.androidDiscoveryIntervalSeconds
      : AppConstants.discoveryIntervalSeconds;

  int get _timeoutSeconds =>
      _quiet ? quietIntervalSeconds * 3 : AppConstants.deviceTimeoutSeconds;

  /// Switches quiet mode (see [quiet]) and restarts the timers it changes.
  void setQuiet(bool quiet) {
    if (_quiet == quiet) return;
    _quiet = quiet;
    _log.info(quiet ? 'Quiet mode (background)' : 'Normal mode');
    if (_socket == null) return;
    _startTimers();
    if (!quiet) {
      _lastPacketReceived = DateTime.now();
      _broadcast();
      unawaited(_probeSilent());
    }
  }

  void _startTimers() {
    _broadcastTimer?.cancel();
    _broadcastTimer = Timer.periodic(
      Duration(seconds: _broadcastSeconds),
      (_) => _broadcast(),
    );
    _probeTimer?.cancel();
    _probeTimer = Timer.periodic(
      Duration(seconds: _quiet ? quietIntervalSeconds : _probeAfterSeconds ~/ 2),
      (_) => _probeSilent(),
    );
  }

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

    _log.info(
      'Starting... (device: ${localDevice.name}, id: ${localDevice.id})',
    );

    // Resolve local IP so we can update localDevice and filter our own packets.
    final localIp = await _getLocalIp();
    _log.info('Local IP resolved: $localIp');
    if (localIp != null && localIp != localDevice.ip) {
      localDevice = localDevice.copyWith(ip: localIp);
    }

    final multicastAddress = InternetAddress(
      AppConstants.multicastGroup,
      type: InternetAddressType.IPv4,
    );

    // Windows & Android/iOS: bind to anyIPv4 so we receive all packet types.
    // Linux/macOS: bind to multicast address (required by kernel for multicast).
    final bindAddress =
        (Platform.isWindows || Platform.isAndroid || Platform.isIOS)
        ? InternetAddress.anyIPv4
        : multicastAddress;

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
          _log.error(
            'ALL bind attempts failed. Discovery will not receive packets.',
          );
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

    _log.info(
      'Multicast joined. Listening on port $boundPort, broadcasting to ${AppConstants.discoveryPort}.',
    );

    // On Windows with virtual adapters (Hyper-V, WSL), the main socket bound
    // to anyIPv4 may send multicast/broadcast through the wrong interface
    // (the one with the lowest routing metric). Open a dedicated send socket
    // bound to the real LAN IP so all outbound discovery packets go through
    // the physical adapter. The main socket remains on anyIPv4 for receiving.
    if (Platform.isWindows && localIp != null && localIp.isNotEmpty) {
      try {
        _sendSocket = await RawDatagramSocket.bind(
          InternetAddress(localIp),
          0, // ephemeral port — we only send from this socket
          reuseAddress: true,
        );
        _sendSocket!.broadcastEnabled = true;
        _sendSocket!.multicastLoopback = true;
        _log.info(
          'Dedicated send socket bound to $localIp (ensures correct interface).',
        );
      } catch (e) {
        _log.warning('Could not create dedicated send socket: $e');
        // Fall back to main socket for sending.
      }
    }

    // Reset failure counters.
    _consecutiveBroadcastFailures = 0;
    _lastPacketReceived = DateTime.now();

    // Listen for incoming datagrams.
    _socketSub = _socket!.listen(
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
        if (_isStopping) return; // Deliberate stop, not unexpected.
        _log.warning('Socket stream closed unexpectedly — triggering restart');
        _socket = null;
        _scheduleRestart();
      },
    );

    // Broadcast our own info periodically.
    _broadcast();

    // Run the cleanup pass every 5 seconds to remove stale devices.
    _cleanupTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _cleanupStaleDevices(),
    );

    // Periodically re-join multicast group. A two-minute interval is enough to
    // recover dropped memberships without repeatedly waking mobile radios.
    // Some OS/router combos silently drop the IGMP membership, and Wi-Fi
    // power save can cause the chipset to leave the multicast group.
    _rejoinTimer = Timer.periodic(
      const Duration(seconds: AppConstants.multicastRejoinSeconds),
      (_) => _rejoinMulticast(),
    );

    // Health check every 30 seconds: if we're broadcasting but haven't
    // received ANY packet (including our own loopback) in 60 seconds,
    // the socket is probably dead.
    _healthCheckTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _healthCheck(),
    );

    _startTimers();
    unawaited(_probeSilent());
  }

  /// Whether a deliberate stop is in progress (suppresses onDone restart).
  bool _isStopping = false;

  /// Stops the discovery service without disposing streams.
  ///
  /// The service can be restarted via [start] after stopping.
  void stop() {
    _isStopping = true;

    _broadcastTimer?.cancel();
    _broadcastTimer = null;

    _cleanupTimer?.cancel();
    _cleanupTimer = null;

    _rejoinTimer?.cancel();
    _rejoinTimer = null;

    _healthCheckTimer?.cancel();
    _healthCheckTimer = null;

    _probeTimer?.cancel();
    _probeTimer = null;

    _socketSub?.cancel();
    _socketSub = null;

    try {
      _sendSocket?.close();
    } catch (_) {}
    _sendSocket = null;

    try {
      _socket?.close();
    } catch (_) {
      // Ignore close errors.
    }
    _socket = null;

    _isStopping = false;
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

  /// Whether a [NetworkInterface] is a virtual adapter (Hyper-V, VMware, etc.).
  static bool _isVirtualInterface(NetworkInterface iface) {
    final name = iface.name.toLowerCase();
    return name.contains('vmware') ||
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
  }

  /// Joins the multicast group on every available IPv4 network interface,
  /// skipping virtual adapters (Hyper-V, VMware, Docker, etc.).
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
    } catch (e) {
      _log.debug('Plain multicast join failed (may be normal): $e');
    }

    // 2. Then try joining on each specific interface for better coverage,
    //    but skip virtual adapters that can interfere with multicast.
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
      );
      for (final iface in interfaces) {
        if (_isVirtualInterface(iface)) {
          _log.debug('Skipping virtual interface for multicast: ${iface.name}');
          continue;
        }
        try {
          _socket!.joinMulticast(multicastAddress, iface);
          _log.debug('Multicast joined on ${iface.name}');
        } catch (e) {
          _log.debug('Multicast join on ${iface.name} failed: $e');
        }
      }
    } catch (e) {
      _log.warning('Could not enumerate network interfaces: $e');
    }
  }

  /// Re-joins the multicast group on all interfaces.
  ///
  /// Called periodically to counter OS/router silently dropping the IGMP
  /// membership. This is a common cause of "devices stop seeing each other
  /// after a while" on LAN networks.
  Future<void> _rejoinMulticast() async {
    if (_socket == null || _quiet) return;

    _log.debug('Periodic multicast re-join...');
    final multicastAddress = InternetAddress(
      AppConstants.multicastGroup,
      type: InternetAddressType.IPv4,
    );

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
    if (_socket == null || _quiet) return;

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
  /// Uses a triple-send strategy for maximum reliability:
  /// 1. Multicast to the group address (standard discovery).
  /// 2. Subnet broadcast (255.255.255.255) for networks blocking multicast.
  /// 3. Direct unicast to every known device (guarantees delivery even when
  ///    both multicast and broadcast are flaky on Wi-Fi).
  ///
  /// Tracks consecutive failures. If [_maxConsecutiveFailures] is reached,
  /// triggers a full socket restart.
  void _broadcast() {
    if (_socket == null) return;

    try {
      // in the background the phone says so ("sessiz"): its timers barely run
      // while it sleeps, so the others keep it listed longer and wait longer
      // for it to wake when they ask (see [quietCapability])
      final me = _quiet && !localDevice.capabilities.contains(quietCapability)
          ? localDevice.copyWith(capabilities: [...localDevice.capabilities, quietCapability])
          : localDevice;
      final data = utf8.encode(jsonEncode(me.toJson()));

      // Use the dedicated send socket (bound to real LAN IP) on Windows to
      // avoid Hyper-V / WSL virtual adapter routing. Falls back to the main
      // socket on other platforms or if the send socket wasn't created.
      final outSock = _sendSocket ?? _socket!;

      // 1. Multicast
      outSock.send(
        data,
        InternetAddress(AppConstants.multicastGroup),
        AppConstants.discoveryPort,
      );

      // 2. Subnet broadcast fallback (works even when multicast is blocked).
      //    Send from BOTH sockets on Windows: the main socket (anyIPv4) can
      //    reach the global broadcast while the send socket targets the LAN.
      _socket!.send(
        data,
        InternetAddress('255.255.255.255'),
        AppConstants.discoveryPort,
      );

      // 3. Subnet-specific broadcast (e.g. 192.168.1.255).
      //    Some routers drop 255.255.255.255 but honour directed broadcast.
      final myIp = localDevice.ip;
      if (myIp.isNotEmpty && myIp.contains('.')) {
        try {
          final parts = myIp.split('.');
          if (parts.length == 4) {
            final subnetBroadcast = '${parts[0]}.${parts[1]}.${parts[2]}.255';
            outSock.send(
              data,
              InternetAddress(subnetBroadcast),
              AppConstants.discoveryPort,
            );
          }
        } catch (_) {}
      }

      // 4. Direct unicast to every known device — guarantees delivery even
      //    when multicast/broadcast packets are dropped by Wi-Fi power save.
      for (final device in _devices.values) {
        if (device.ip.isNotEmpty && device.ip != localDevice.ip) {
          try {
            outSock.send(
              data,
              InternetAddress(device.ip),
              AppConstants.discoveryPort,
            );
          } catch (_) {}
        }
      }

      // Reset failure counter on success.
      _consecutiveBroadcastFailures = 0;
    } catch (e) {
      _consecutiveBroadcastFailures++;
      _log.warning(
        'Broadcast failed ($_consecutiveBroadcastFailures/$_maxConsecutiveFailures)',
        error: e,
      );

      if (_consecutiveBroadcastFailures >= _maxConsecutiveFailures) {
        _log.error(
          'Too many consecutive broadcast failures — socket is dead, restarting.',
        );
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

      // Always use the datagram source address as the canonical IP.
      // The payload IP may be wrong (e.g. Android without location permission
      // picks the wrong interface), but the source address is always the real,
      // routable IP that delivered the packet to us.
      final sourceIp = datagram.address.address;
      if (device.ip.isNotEmpty && device.ip != sourceIp) {
        _log.debug(
          'IP mismatch for ${device.name}: payload=${device.ip}, '
          'source=$sourceIp — using source IP',
        );
      }
      final updatedDevice = device.copyWith(
        ip: sourceIp,
        lastSeen: DateTime.now(),
      );

      _devices[updatedDevice.id] = updatedDevice;

      // Always emit so UI stays in sync (lastSeen, name, ip changes, etc.).
      _emitDevices();
    } catch (e) {
      _log.debug(
        'Malformed discovery packet from ${datagram.address.address}: $e',
      );
    }
  }

  /// Asks the devices gone quiet, and the paired ones not heard at all, at
  /// their last address. One short GET each; nothing when all are heard.
  Future<void> _probeSilent() async {
    if (_socket == null || _probing) return;
    _probing = true;
    try {
      final now = DateTime.now();
      final targets = <String, ({String ip, int port})>{};
      for (final d in _devices.values) {
        // a phone in the background is asked once a minute, not every few seconds
        final after = _isQuiet(d) ? 60 : _probeAfterSeconds;
        if (now.difference(d.lastSeen).inSeconds >= after &&
            d.ip.isNotEmpty) {
          targets[d.id] = (ip: d.ip, port: d.port);
        }
      }
      for (final peer in knownPeers?.call() ?? const []) {
        if (peer.ip.isEmpty || _devices.containsKey(peer.id)) continue;
        targets[peer.id] = (ip: peer.ip, port: AppConstants.defaultPort);
      }
      await Future.wait(
        targets.entries.map((e) => _probe(e.key, e.value.ip, e.value.port)),
      );
    } finally {
      _probing = false;
    }
  }

  Future<void> _probe(String id, String ip, int port) async {
    // a sleeping phone's Wi-Fi wakes only at its next beacon: give it time
    final wasQuiet = _devices[id] != null && _isQuiet(_devices[id]!);
    final wait = Duration(milliseconds: wasQuiet ? 6000 : 1500);
    final client = HttpClient()..connectionTimeout = wait;
    try {
      final request = await client
          .getUrl(Uri.http('$ip:$port', '/api/info'))
          .timeout(wait);
      final response = await request.close().timeout(wait);
      if (response.statusCode != 200) {
        await response.drain<void>();
        return;
      }
      final body = await response.transform(utf8.decoder).join();
      final device = Device.fromJson(jsonDecode(body) as Map<String, dynamic>);
      if (device.id != id || device.id == localDevice.id) return;
      // /api/info does not say it is in the background; its last announcement did
      final caps = wasQuiet && !_isQuiet(device) ? [...device.capabilities, quietCapability] : null;
      _devices[id] = device.copyWith(ip: ip, lastSeen: DateTime.now(), capabilities: caps);
      _probeMisses.remove(id);
      _emitDevices();
    } catch (_) {
      // not there: it leaves the list after the usual timeout; a quiet phone
      // that did not answer three times running has really gone
      if (wasQuiet && (_probeMisses[id] = (_probeMisses[id] ?? 0) + 1) >= 3) {
        _probeMisses.remove(id);
        if (_devices.remove(id) != null) _emitDevices();
      }
    } finally {
      client.close(force: true);
    }
  }

  final Map<String, int> _probeMisses = {};

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
      final limit = _isQuiet(entry.value) ? quietDeviceTimeoutSeconds : _timeoutSeconds;
      if (elapsed > limit) {
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
        for (final addr in iface.addresses) {
          if (addr.isLoopback) continue;
          fallback ??= addr.address;
          if (_isVirtualInterface(iface)) continue;
          if (addr.address.startsWith('192.168.') ||
              addr.address.startsWith('10.')) {
            return addr.address;
          }
        }
      }

      // Any non-virtual, non-loopback.
      for (final iface in interfaces) {
        if (_isVirtualInterface(iface)) continue;
        for (final addr in iface.addresses) {
          if (!addr.isLoopback) return addr.address;
        }
      }

      return fallback;
    } catch (_) {}

    return null;
  }
}
