import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:anyware/core/logger.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import 'package:anyware/core/constants.dart';
import 'package:anyware/features/discovery/domain/device.dart';
import 'package:anyware/features/discovery/presentation/providers.dart';
import 'package:anyware/features/sync/data/cancellation_token.dart';
import 'package:anyware/features/sync/domain/sync_manifest.dart';
import 'package:anyware/features/sync/domain/sync_state.dart';

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

  /// Sends a sync setup request to the target device.
  ///
  /// This is the first step of the sync handshake protocol. The receiver
  /// will show an acceptance dialog where the user can select a target folder.
  ///
  /// Returns a map with `accepted` (bool) and optionally `receiveFolder` (String)
  /// on success, or `null` if the request failed (e.g. old receiver without
  /// setup-request support → fallback to direct sync).
  Future<Map<String, dynamic>?> sendSyncSetupRequest(
    Device target, {
    required String jobId,
    required String jobName,
    required String senderDeviceId,
    required String senderDeviceName,
    required SyncDirection direction,
    String? senderIp,
    String? remoteBaseDir,
    int fileCount = 0,
    int totalSize = 0,
  }) async {
    try {
      final uri = Uri.parse(
        'http://${target.ip}:${AppConstants.defaultPort}/api/sync/setup-request',
      );

      // 120-second timeout so the user has time to pick a folder.
      final response = await http.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'jobId': jobId,
          'jobName': jobName,
          'senderDeviceId': senderDeviceId,
          'senderDeviceName': senderDeviceName,
          'senderIp': senderIp ?? '', // Sender's own IP for reverse calls.
          if (remoteBaseDir != null) 'remoteBaseDir': remoteBaseDir,
          'direction': direction.name,
          'fileCount': fileCount,
          'totalSize': totalSize,
        }),
      ).timeout(const Duration(seconds: 120));

      if (response.statusCode == 200) {
        final body = jsonDecode(response.body) as Map<String, dynamic>;
        _log.info('Setup request response from ${target.name}: $body');
        return body;
      } else if (response.statusCode == 404) {
        // Old receiver without setup-request support → fallback.
        _log.info('Setup request not supported by ${target.name} (404)');
        return null;
      } else {
        _log.warning(
            'Setup request failed: ${response.statusCode} ${response.body}');
        return null;
      }
    } catch (e) {
      _log.warning('Setup request error for ${target.name}: $e');
      return null;
    }
  }

  /// Notifies a remote device that a sync pairing/job has been removed.
  ///
  /// Best-effort: errors are silently swallowed (the other device may be
  /// offline). The remote side should remove the corresponding pairing or job.
  Future<bool> sendRemovePairing(
    Device target, {
    required String jobId,
    required String senderDeviceId,
  }) async {
    try {
      final uri = Uri.parse(
        'http://${target.ip}:${AppConstants.defaultPort}/api/sync/remove-pairing',
      );
      final response = await http
          .post(
            uri,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'jobId': jobId,
              'senderDeviceId': senderDeviceId,
            }),
          )
          .timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        _log.info('Remote pairing removal acknowledged by ${target.name}');
        return true;
      }
      _log.warning('Remote pairing removal failed: ${response.statusCode}');
      return false;
    } catch (e) {
      _log.info('Could not notify ${target.name} about pairing removal '
          '(device may be offline): $e');
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
    String senderName, {
    String? jobId,
    String? jobName,
  }) async {
    try {
      final uri = Uri.parse(
        'http://${target.ip}:${AppConstants.defaultPort}/api/sync/check',
      ).replace(queryParameters: {
        'path': relativePath,
        'sender': senderName,
        if (jobId != null) 'jobId': jobId,
        if (jobName != null) 'jobName': jobName,
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
  /// When [isPhotoMode] is `true`, the relative path is rewritten to include
  /// a date-based subfolder (e.g. `2026/02/photo.jpg`) derived from the
  /// file's last-modified timestamp.
  ///
  /// Returns `null` on success, or a non-null error message on failure.
  Future<String?> sendFile(
    Device target,
    String filePath,
    String baseDirectory, {
    bool isPhotoMode = false,
    String dateSubfolderFormat = 'YYYY/MM',
    bool convertHeicToJpg = false,
    String? jobId,
    String? jobName,
    CancellationToken? cancel,
  }) async {
    final file = File(filePath);
    if (!await file.exists()) return 'File does not exist: $filePath';

    final fileName = p.basename(filePath);

    // ── HEIC → JPG conversion (photo mode) ──
    // Full image re-encoding requires a native library (planned for a
    // future update). For now we log and send the original file unchanged.
    if (convertHeicToJpg && _isHeicFile(fileName)) {
      _log.info('HEIC file detected: $fileName (conversion placeholder)');
    }

    // Calculate relative path for mirroring (e.g., 'docs/report.pdf')
    var relativePath = p.relative(filePath, from: baseDirectory)
        .replaceAll(r'\', '/');

    // ── Photo mode: date-based subfolder ──
    if (isPhotoMode) {
      relativePath = await _applyDateSubfolder(file, fileName, dateSubfolderFormat);
    }

    final discoveryService = ref.read(discoveryServiceProvider).valueOrNull;
    if (discoveryService == null) return 'Discovery service not available';

    final senderDevice = discoveryService.localDevice;

    try {
      // Check cancellation before starting network operations.
      if (cancel != null && cancel.isCancelled) return 'Cancelled';

      final requestUrl = Uri.parse(
        'http://${target.ip}:${AppConstants.defaultPort}/api/sync/upload',
      );

      final fileSize = await file.length();

      // ── Upload resume: check for partial temp file on server ──
      int uploadOffset = 0;
      try {
        final checkResult = await checkFileStatus(
          target, relativePath, senderDevice.name,
          jobId: jobId, jobName: jobName,
        );
        if (checkResult != null) {
          final tempSize = checkResult['tempSize'] as int? ?? 0;
          if (tempSize > 0 && tempSize < fileSize) {
            uploadOffset = tempSize;
            _log.info(
              'Server has partial upload for $relativePath: '
              '$uploadOffset / $fileSize bytes',
            );
          }
        }
      } catch (e) {
        _log.debug('Upload resume check failed (starting fresh): $e');
      }

      final request = http.MultipartRequest('POST', requestUrl);

      // Compute SHA-256 for integrity verification (files <= 50 MB).
      // Hash is always computed over the FULL file regardless of offset.
      String? fileHash;
      if (fileSize <= 50 * 1024 * 1024) {
        final digest = await sha256.bind(file.openRead()).last;
        fileHash = digest.toString();
      }

      request.headers.addAll({
        'X-Sync-Path': Uri.encodeFull(relativePath),
        'X-Device-Id': senderDevice.id,
        'X-Device-Name': Uri.encodeFull(senderDevice.name),
        if (jobId != null) 'X-Sync-Job-Id': jobId,
        if (jobName != null) 'X-Sync-Job-Name': Uri.encodeFull(jobName),
        if (fileHash != null) 'X-Sync-Hash': fileHash,
        if (uploadOffset > 0) 'X-Offset': uploadOffset.toString(),
        'X-Total-Size': fileSize.toString(),
      });

      if (uploadOffset > 0) {
        // Stream only the remaining bytes from the offset.
        final remaining = fileSize - uploadOffset;
        request.files.add(
          http.MultipartFile(
            'file',
            file.openRead(uploadOffset),
            remaining,
            filename: fileName,
          ),
        );
      } else {
        request.files.add(
          await http.MultipartFile.fromPath(
            'file',
            file.path,
            filename: fileName,
          ),
        );
      }

      // Dynamic timeout based on file size (min 5 min, +1 min per 5 MB).
      final fileSizeMB = fileSize / (1024 * 1024);
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

  /// Computes a date-based relative path for photo mode files.
  ///
  /// Format examples:
  /// - `YYYY/MM`     → `2026/02/IMG_001.jpg`
  /// - `YYYY-MM-DD`  → `2026-02-22/IMG_001.jpg`
  /// - `YYYY`        → `2026/IMG_001.jpg`
  Future<String> _applyDateSubfolder(
    File file,
    String fileName,
    String format,
  ) async {
    DateTime date;
    try {
      date = await file.lastModified();
    } catch (_) {
      date = DateTime.now();
    }

    final yyyy = date.year.toString();
    final mm = date.month.toString().padLeft(2, '0');
    final dd = date.day.toString().padLeft(2, '0');

    String subfolder;
    switch (format) {
      case 'YYYY/MM':
        subfolder = '$yyyy/$mm';
        break;
      case 'YYYY-MM-DD':
        subfolder = '$yyyy-$mm-$dd';
        break;
      case 'YYYY':
        subfolder = yyyy;
        break;
      default:
        subfolder = '$yyyy/$mm';
    }

    return '$subfolder/$fileName';
  }

  /// Returns `true` if the file extension suggests HEIC/HEIF format.
  static bool _isHeicFile(String fileName) {
    final lower = fileName.toLowerCase();
    return lower.endsWith('.heic') || lower.endsWith('.heif');
  }

  /// Sends a delete request for a file that was removed from the source directory.
  ///
  /// Returns true if successful, false otherwise.
  Future<bool> sendDelete(
    Device target,
    String filePath,
    String baseDirectory, {
    String? jobId,
    String? jobName,
  }) async {
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
          if (jobId != null) 'jobId': jobId,
          if (jobName != null) 'jobName': jobName,
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

  // ═══════════════════════════════════════════════════════════════════════════
  // Bidirectional sync support
  // ═══════════════════════════════════════════════════════════════════════════

  /// Fetches the file manifest from a remote device's sync directory.
  ///
  /// [senderName] is our local device name so the remote can locate the
  /// correct sync folder (e.g. `Downloads/Sync/<senderName>/`).
  /// [basePath] overrides the default sync folder if provided.
  ///
  /// Returns `null` on failure.
  Future<SyncManifest?> getRemoteManifest(
    Device target, {
    required String senderName,
    String? basePath,
    String? jobId,
    String? jobName,
  }) async {
    try {
      final uri = Uri.parse(
        'http://${target.ip}:${AppConstants.defaultPort}/api/sync/manifest',
      );

      final response = await http.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'senderName': senderName,
          if (basePath != null) 'basePath': basePath,
          if (jobId != null) 'jobId': jobId,
          if (jobName != null) 'jobName': jobName,
        }),
      ).timeout(const Duration(seconds: 30));

      if (response.statusCode == 200) {
        final json = jsonDecode(response.body) as Map<String, dynamic>;
        return SyncManifest.fromJson(json);
      }
      _log.warning('Remote manifest request failed: ${response.statusCode}');
      return null;
    } catch (e) {
      _log.error('Error fetching remote manifest from ${target.name}: $e',
          error: e);
      return null;
    }
  }

  /// Pulls (downloads) a single file from a remote device.
  ///
  /// The file is saved to [localPath] with intermediate directories created
  /// as needed. Returns `null` on success, or an error message on failure.
  Future<String?> pullFile(
    Device target, {
    required String relativePath,
    required String localBasePath,
    required String senderName,
    String? basePath,
    String? jobId,
    String? jobName,
    CancellationToken? cancel,
  }) async {
    try {
      // Check cancellation before starting network operations.
      if (cancel != null && cancel.isCancelled) return 'Cancelled';

      final queryParams = {
        'path': relativePath,
        'sender': senderName,
        if (basePath != null) 'basePath': basePath,
        if (jobId != null) 'jobId': jobId,
        if (jobName != null) 'jobName': jobName,
      };

      final uri = Uri.parse(
        'http://${target.ip}:${AppConstants.defaultPort}/api/sync/pull',
      ).replace(queryParameters: queryParams);

      // Create target directory.
      final localFilePath = p.normalize(
        p.join(localBasePath, relativePath.replaceAll('/', p.separator)),
      );
      final dir = Directory(p.dirname(localFilePath));
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }

      // ── Byte-level resume: check for existing temp file ──
      final tempFilePath = '$localFilePath.sync_tmp';
      final tempFile = File(tempFilePath);
      int resumeOffset = 0;
      if (await tempFile.exists()) {
        resumeOffset = await tempFile.length();
        _log.info(
          'Found partial temp file for $relativePath: $resumeOffset bytes',
        );
      }

      final client = http.Client();
      try {
        final request = http.Request('GET', uri);
        if (resumeOffset > 0) {
          request.headers['Range'] = 'bytes=$resumeOffset-';
        }
        final streamedResponse = await client.send(request).timeout(
              const Duration(minutes: 10),
            );

        if (streamedResponse.statusCode != 200 &&
            streamedResponse.statusCode != 206) {
          final body = await streamedResponse.stream.bytesToString();
          return 'HTTP ${streamedResponse.statusCode}: $body';
        }

        // Determine write mode: append on 206 (partial), fresh on 200.
        FileMode writeMode = FileMode.write;
        if (streamedResponse.statusCode == 206 && resumeOffset > 0) {
          writeMode = FileMode.append;
          _log.info('Resuming pull of $relativePath from byte $resumeOffset');
        } else {
          resumeOffset = 0; // Fresh download.
        }

        // Stream to temp file with cancellation support.
        final sink = tempFile.openWrite(mode: writeMode);
        bool cancelled = false;
        await for (final chunk in streamedResponse.stream) {
          if (cancel != null && cancel.isCancelled) {
            cancelled = true;
            break;
          }
          sink.add(chunk);
        }
        await sink.flush();
        await sink.close();
        if (cancelled) {
          // Leave temp file for resume on next attempt.
          client.close();
          return 'Cancelled';
        }

        // Atomic rename (copy+delete fallback for Android scoped storage).
        try {
          await tempFile.rename(localFilePath);
        } catch (_) {
          await tempFile.copy(localFilePath);
          await tempFile.delete();
        }

        // Verify hash if the server provided one.
        final hashHeader = streamedResponse.headers['x-content-hash'];
        if (hashHeader != null && hashHeader.isNotEmpty) {
          final digest =
              await sha256.bind(File(localFilePath).openRead()).last;
          final actualHash = digest.toString();
          if (actualHash != hashHeader) {
            _log.error('Pull hash mismatch for $relativePath: '
                'expected=$hashHeader, actual=$actualHash');
            await File(localFilePath).delete();
            return 'Hash mismatch: expected $hashHeader, got $actualHash';
          }
          _log.info('SHA-256 verified for pulled file: $relativePath');
        }

        // Restore last-modified from header if available.
        final file = File(localFilePath);
        final lastModifiedHeader =
            streamedResponse.headers['x-last-modified'];
        if (lastModifiedHeader != null) {
          try {
            final dt = DateTime.parse(lastModifiedHeader);
            await file.setLastModified(dt);
          } catch (_) {
            // Ignore timestamp restoration failures.
          }
        }

        _log.info('Pulled $relativePath from ${target.name}');
        return null; // Success
      } finally {
        client.close();
      }
    } catch (e) {
      final errorMsg = e.toString();
      _log.error('Error pulling $relativePath from ${target.name}: $errorMsg',
          error: e);
      return errorMsg;
    }
  }

  /// Sends a delete request for a file on the remote device.
  /// Used in bidirectional sync when a local deletion should be mirrored.
  ///
  /// [basePath] overrides the default sync folder on the remote.
  Future<bool> sendDeleteBidirectional(
    Device target, {
    required String relativePath,
    required String senderName,
    required String senderDeviceId,
    String? basePath,
    String? jobId,
    String? jobName,
  }) async {
    try {
      final requestUrl = Uri.parse(
        'http://${target.ip}:${AppConstants.defaultPort}/api/sync/delete',
      );

      final response = await http.post(
        requestUrl,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'relativePath': relativePath,
          'senderName': senderName,
          'senderDeviceId': senderDeviceId,
          if (basePath != null) 'basePath': basePath,
          if (jobId != null) 'jobId': jobId,
          if (jobName != null) 'jobName': jobName,
        }),
      ).timeout(const Duration(seconds: 30));

      if (response.statusCode == 200) {
        _log.info('Bidirectional delete $relativePath on ${target.name}');
        return true;
      }
      _log.warning(
          'Bidirectional delete failed: $relativePath - ${response.statusCode}');
      return false;
    } catch (e) {
      _log.error('Error in bidirectional delete $relativePath: $e', error: e);
      return false;
    }
  }
}
