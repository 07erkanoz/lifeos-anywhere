import 'dart:convert';
import 'dart:io';

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

  /// Sends a file silently to the target device for synchronization.
  ///
  /// Returns true if successful, false otherwise.
  Future<bool> sendFile(Device target, String filePath, String baseDirectory) async {
    final file = File(filePath);
    if (!file.existsSync()) return false;

    final fileName = p.basename(filePath);

    // Calculate relative path for mirroring (e.g., 'docs/report.pdf')
    final relativePath = p.relative(filePath, from: baseDirectory);

    final discoveryService = ref.read(discoveryServiceProvider).valueOrNull;
    if (discoveryService == null) return false;

    final senderDevice = discoveryService.localDevice;

    try {
      final requestUrl = Uri.parse(
        'http://${target.ip}:${AppConstants.defaultPort}/api/sync/upload',
      );

      final request = http.MultipartRequest('POST', requestUrl);

      request.headers.addAll({
        'X-Sync-Path': relativePath,
        'X-Device-Id': senderDevice.id,
        'X-Device-Name': senderDevice.name,
      });

      request.files.add(
        await http.MultipartFile.fromPath(
          'file',
          filePath,
          filename: fileName,
        ),
      );

      final streamedResponse = await request.send().timeout(
        const Duration(minutes: 5),
      );
      final response = await http.Response.fromStream(streamedResponse);

      if (response.statusCode == 200) {
        return true;
      } else {
        _log.warning('Failed to sync $relativePath - ${response.statusCode} ${response.body}');
        return false;
      }
    } catch (e) {
      _log.error('Error syncing $relativePath - $e', error: e);
      return false;
    }
  }

  /// Sends a delete request for a file that was removed from the source directory.
  ///
  /// Returns true if successful, false otherwise.
  Future<bool> sendDelete(Device target, String filePath, String baseDirectory) async {
    final relativePath = p.relative(filePath, from: baseDirectory);

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
        _log.warning('Failed to delete $relativePath - ${response.statusCode}');
        return false;
      }
    } catch (e) {
      _log.error('Error deleting $relativePath - $e', error: e);
      return false;
    }
  }
}
