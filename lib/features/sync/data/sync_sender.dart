import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:anyware/core/logger.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import 'package:anyware/core/constants.dart';
import 'package:anyware/features/discovery/domain/device.dart';
import 'package:anyware/features/discovery/presentation/providers.dart';

final syncSenderProvider = Provider((ref) => SyncSender(ref));

class SyncSender {
  SyncSender(this.ref);

  static final _log = AppLogger('SyncSender');

  final Ref ref;

  /// Checks if the target device is reachable by hitting /api/ping.
  ///
  /// Returns `true` if the device responds within 5 seconds.
  Future<bool> pingTarget(Device target) async {
    try {
      final pingUri = Uri.parse(
        'http://${target.ip}:${AppConstants.defaultPort}/api/ping',
      );
      final client = http.Client();
      try {
        final response = await client
            .get(pingUri)
            .timeout(const Duration(seconds: 5));
        return response.statusCode == 200;
      } finally {
        client.close();
      }
    } catch (e) {
      _log.warning('Ping failed for ${target.name}: $e');
      return false;
    }
  }

  /// Checks the status of a file on the target device (for smart sync).
  ///
  /// Returns a map with `exists`, `size`, and `lastModified` fields,
  /// or null on failure.
  Future<Map<String, dynamic>?> checkFileStatus(
    Device target,
    String relativePath,
    String senderName,
  ) async {
    try {
      final uri = Uri.parse(
        'http://${target.ip}:${AppConstants.defaultPort}/api/sync/check',
      ).replace(queryParameters: {
        'path': relativePath,
        'sender': senderName,
      });

      final response = await http.get(uri).timeout(const Duration(seconds: 10));
      if (response.statusCode == 200) {
        return jsonDecode(response.body) as Map<String, dynamic>;
      }
      return null;
    } catch (e) {
      _log.warning('Check file status failed for $relativePath: $e');
      return null;
    }
  }

  /// Sends a file silently to the target device for synchronization.
  ///
  /// Returns `null` on success, or a non-null error message on failure.
  Future<String?> sendFile(
    Device target,
    String filePath,
    String baseDirectory,
  ) async {
    final file = File(filePath);
    if (!file.existsSync()) return 'File does not exist: $filePath';

    final fileName = p.basename(filePath);

    // Calculate relative path for mirroring (e.g., 'docs/report.pdf')
    final relativePath = p.relative(filePath, from: baseDirectory)
        .replaceAll(r'\', '/');

    final discoveryService = ref.read(discoveryServiceProvider).valueOrNull;
    if (discoveryService == null) return 'Discovery service not available';

    final senderDevice = discoveryService.localDevice;

    try {
      final requestUrl = Uri.parse(
        'http://${target.ip}:${AppConstants.defaultPort}/api/sync/upload',
      );

      final request = http.MultipartRequest('POST', requestUrl);

      request.headers.addAll({
        'X-Sync-Path': Uri.encodeFull(relativePath),
        'X-Device-Id': senderDevice.id,
        'X-Device-Name': Uri.encodeFull(senderDevice.name),
      });

      request.files.add(
        await http.MultipartFile.fromPath(
          'file',
          filePath,
          filename: fileName,
        ),
      );

      // Dynamic timeout based on file size (min 5 min, +1 min per 5 MB).
      final fileSizeBytes = file.lengthSync();
      final fileSizeMB = fileSizeBytes / (1024 * 1024);
      final timeoutMinutes = max(5, (fileSizeMB / 5).ceil() + 5);

      final streamedResponse = await request.send().timeout(
        Duration(minutes: timeoutMinutes),
      );
      final response = await http.Response.fromStream(streamedResponse);

      if (response.statusCode == 200) {
        return null; // Success
      } else {
        final errorMsg =
            'HTTP ${response.statusCode}: ${response.body}';
        _log.warning('Failed to sync $relativePath - $errorMsg');
        return errorMsg;
      }
    } catch (e) {
      final errorMsg = e.toString();
      _log.error('Error syncing $relativePath - $errorMsg', error: e);
      return errorMsg;
    }
  }

  /// Sends a delete request for a file that was removed from the source directory.
  ///
  /// Returns true if successful, false otherwise.
  Future<bool> sendDelete(
    Device target,
    String filePath,
    String baseDirectory,
  ) async {
    final relativePath = p.relative(filePath, from: baseDirectory)
        .replaceAll(r'\', '/');

    final discoveryService = ref.read(discoveryServiceProvider).valueOrNull;
    if (discoveryService == null) return false;

    final senderDevice = discoveryService.localDevice;

    try {
      final requestUrl = Uri.parse(
        'http://${target.ip}:${AppConstants.defaultPort}/api/sync/delete',
      );

      final response = await http.post(
        requestUrl,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'relativePath': relativePath,
          'senderName': senderDevice.name,
          'senderDeviceId': senderDevice.id,
        }),
      ).timeout(const Duration(seconds: 30));

      if (response.statusCode == 200) {
        _log.info('Deleted $relativePath on ${target.name}');
        return true;
      } else {
        _log.warning(
            'Failed to delete $relativePath - ${response.statusCode}');
        return false;
      }
    } catch (e) {
      _log.error('Error deleting $relativePath - $e', error: e);
      return false;
    }
  }
}
