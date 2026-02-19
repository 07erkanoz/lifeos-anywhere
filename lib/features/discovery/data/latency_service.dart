import 'dart:async';
import 'dart:io';

import 'package:anyware/features/discovery/domain/device.dart';

/// Tracks network latency (round-trip ping time) for discovered devices.
///
/// Periodically sends HTTP GET requests to each device's `/api/ping` endpoint
/// and records the response time. Maintains a rolling window of recent
/// measurements to compute average and current latency.
class LatencyService {
  LatencyService();

  /// Rolling window size for averaging.
  static const int _windowSize = 5;

  /// Per-device latency history: device id → list of recent measurements (ms).
  final Map<String, List<int>> _history = {};

  /// Per-device latest latency in ms. -1 means unreachable.
  final Map<String, int> _current = {};

  final HttpClient _httpClient = HttpClient()
    ..connectionTimeout = const Duration(seconds: 3)
    ..idleTimeout = const Duration(seconds: 5);

  Timer? _timer;

  final StreamController<Map<String, int>> _controller =
      StreamController<Map<String, int>>.broadcast();

  /// Emits the current latency map whenever measurements are updated.
  Stream<Map<String, int>> get latencyUpdates => _controller.stream;

  /// Returns the latest known latency for a device, or null if unknown.
  int? getLatency(String deviceId) => _current[deviceId];

  /// Returns the average latency for a device over the rolling window.
  int? getAverageLatency(String deviceId) {
    final history = _history[deviceId];
    if (history == null || history.isEmpty) return null;
    final valid = history.where((ms) => ms >= 0).toList();
    if (valid.isEmpty) return null;
    return valid.reduce((a, b) => a + b) ~/ valid.length;
  }

  /// Returns a snapshot of all current latencies.
  Map<String, int> get currentLatencies => Map.unmodifiable(_current);

  /// Starts periodic latency measurement for the given [devices].
  ///
  /// Call [updateDevices] to change the device list without restarting.
  void start(List<Device> devices, {Duration interval = const Duration(seconds: 10)}) {
    _timer?.cancel();
    _measureAll(devices);
    _timer = Timer.periodic(interval, (_) => _measureAll(devices));
  }

  /// Active device list for the running timer.
  List<Device> _activeDevices = [];

  /// Updates the list of devices to ping without restarting the timer.
  void updateDevices(List<Device> devices) {
    _activeDevices = devices;

    // Clean up entries for devices no longer in the list.
    final activeIds = devices.map((d) => d.id).toSet();
    _history.removeWhere((id, _) => !activeIds.contains(id));
    _current.removeWhere((id, _) => !activeIds.contains(id));
  }

  /// Starts periodic measurement using [updateDevices] for dynamic lists.
  void startDynamic({Duration interval = const Duration(seconds: 10)}) {
    _timer?.cancel();
    _timer = Timer.periodic(interval, (_) => _measureAll(_activeDevices));
  }

  /// Pings a single device and returns the latency in milliseconds.
  /// Returns -1 if the device is unreachable.
  Future<int> pingDevice(Device device) async {
    final stopwatch = Stopwatch()..start();
    try {
      final uri = Uri.http('${device.ip}:${device.port}', '/api/ping');
      final request = await _httpClient.getUrl(uri);
      final response = await request.close().timeout(
        const Duration(seconds: 3),
      );
      await response.drain<void>();
      stopwatch.stop();

      if (response.statusCode == 200) {
        return stopwatch.elapsedMilliseconds;
      }
      return -1;
    } catch (_) {
      stopwatch.stop();
      return -1;
    }
  }

  /// Measures latency for all devices in parallel.
  Future<void> _measureAll(List<Device> devices) async {
    if (devices.isEmpty) return;

    final futures = devices.map((device) async {
      final ms = await pingDevice(device);
      _recordMeasurement(device.id, ms);
    });

    await Future.wait(futures);

    if (!_controller.isClosed) {
      _controller.add(Map.unmodifiable(_current));
    }
  }

  void _recordMeasurement(String deviceId, int ms) {
    _current[deviceId] = ms;

    final history = _history.putIfAbsent(deviceId, () => []);
    history.add(ms);
    if (history.length > _windowSize) {
      history.removeAt(0);
    }
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  void dispose() {
    stop();
    _httpClient.close(force: true);
    _controller.close();
    _history.clear();
    _current.clear();
  }
}

/// Human-readable latency label.
String formatLatency(int? ms) {
  if (ms == null) return '';
  if (ms < 0) return 'offline';
  if (ms < 1) return '<1 ms';
  return '$ms ms';
}

/// Returns a quality indicator for the given latency.
enum LatencyQuality { excellent, good, fair, poor, offline, unknown }

LatencyQuality latencyQuality(int? ms) {
  if (ms == null) return LatencyQuality.unknown;
  if (ms < 0) return LatencyQuality.offline;
  if (ms <= 10) return LatencyQuality.excellent;
  if (ms <= 50) return LatencyQuality.good;
  if (ms <= 200) return LatencyQuality.fair;
  return LatencyQuality.poor;
}
