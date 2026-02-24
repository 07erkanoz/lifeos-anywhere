import 'dart:convert';

import 'package:http/http.dart' as http;

import 'package:anyware/core/logger.dart';
import 'package:anyware/features/server_sync/data/cloud_transport.dart';

final _log = AppLogger('LanRemoteBrowser');

/// Browses the file system of a LAN device by calling the `/api/browse`
/// endpoint exposed by [FileServer].
///
/// Implements [RemoteBrowser] so it can be used with the shared
/// [RemoteFolderBrowser] UI widget.
class LanRemoteBrowser implements RemoteBrowser {
  /// IP address of the target device.
  final String deviceIp;

  /// HTTP port of the target device's [FileServer].
  final int devicePort;

  /// Optional device name shown in the browser title.
  final String? deviceName;

  /// HTTP client (injectable for testing).
  final http.Client _client;

  LanRemoteBrowser({
    required this.deviceIp,
    required this.devicePort,
    this.deviceName,
    http.Client? client,
  }) : _client = client ?? http.Client();

  @override
  String get rootPath => ''; // empty → platform roots

  @override
  Future<List<RemoteEntry>> listDirectory(String path) async {
    try {
      final uri = Uri.http(
        '$deviceIp:$devicePort',
        '/api/browse',
        {if (path.isNotEmpty) 'path': path},
      );

      final response = await _client.get(uri).timeout(
            const Duration(seconds: 10),
          );

      if (response.statusCode != 200) {
        _log.error('Browse failed: ${response.statusCode} ${response.body}');
        throw Exception('Browse failed (${response.statusCode})');
      }

      final list = jsonDecode(response.body) as List;
      return list
          .map((e) => RemoteEntry.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (e) {
      _log.error('LAN browse error ($deviceIp:$devicePort, path=$path): $e');
      rethrow;
    }
  }

  /// Disposes the HTTP client.
  void dispose() {
    _client.close();
  }
}
