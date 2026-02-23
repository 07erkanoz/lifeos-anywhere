import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:mime/mime.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf_router/shelf_router.dart';
import 'package:anyware/core/constants.dart';
import 'package:anyware/core/logger.dart';
import 'package:anyware/features/discovery/domain/device.dart';
import 'package:anyware/features/portal/data/portal_html.dart';

final _log = AppLogger('Portal');

/// Registers Web Portal routes onto an existing [Router].
///
/// The portal allows any browser on the LAN to:
///   - View the device name and status.
///   - Upload files to this device's download folder.
///   - Browse and download files from the download folder.
void registerPortalRoutes(
  Router router, {
  required Device Function() getDevice,
  required String Function() getDownloadPath,
}) {
  // Main portal HTML page.
  router.get('/portal', (shelf.Request request) {
    return shelf.Response.ok(
      portalHtml,
      headers: {'Content-Type': 'text/html; charset=utf-8'},
    );
  });

  // Device info API for the portal UI.
  router.get('/portal/api/info', (shelf.Request request) {
    final device = getDevice();
    return shelf.Response.ok(
      jsonEncode({
        'name': device.name,
        'platform': device.platform,
        'version': AppConstants.appVersion,
      }),
      headers: {'Content-Type': 'application/json'},
    );
  });

  // List files in the download folder.
  router.get('/portal/api/files', (shelf.Request request) {
    final downloadPath = getDownloadPath();
    final dir = Directory(downloadPath);

    if (!dir.existsSync()) {
      return shelf.Response.ok(
        jsonEncode(<Map<String, dynamic>>[]),
        headers: {'Content-Type': 'application/json'},
      );
    }

    final files = <Map<String, dynamic>>[];
    for (final entity in dir.listSync()) {
      if (entity is File) {
        final stat = entity.statSync();
        files.add({
          'name': p.basename(entity.path),
          'size': stat.size,
          'modified': stat.modified.toIso8601String(),
        });
      }
    }

    // Sort by most recent first.
    files.sort((a, b) =>
        (b['modified'] as String).compareTo(a['modified'] as String));

    return shelf.Response.ok(
      jsonEncode(files),
      headers: {'Content-Type': 'application/json'},
    );
  });

  // Download a specific file.
  router.get('/portal/api/download/<fileName>',
      (shelf.Request request, String fileName) async {
    final downloadPath = getDownloadPath();
    final sanitized = p.basename(fileName); // Prevent path traversal.
    final file = File(p.join(downloadPath, sanitized));

    if (!file.existsSync()) {
      return shelf.Response.notFound('File not found');
    }

    // Verify file is within the download directory.
    final resolvedPath = file.resolveSymbolicLinksSync();
    final resolvedDir = Directory(downloadPath).resolveSymbolicLinksSync();
    if (!p.isWithin(resolvedDir, resolvedPath)) {
      _log.warning('Portal: blocked path traversal attempt for $fileName');
      return shelf.Response.forbidden('Access denied');
    }

    final mimeType =
        lookupMimeType(sanitized) ?? 'application/octet-stream';

    return shelf.Response.ok(
      file.openRead(),
      headers: {
        'Content-Type': mimeType,
        'Content-Disposition': 'attachment; filename="$sanitized"',
        'Content-Length': '${file.lengthSync()}',
      },
    );
  });

  // Upload files via multipart form data.
  router.post('/portal/api/upload',
      (shelf.Request request) async {
    final downloadPath = getDownloadPath();
    final contentType = request.headers['content-type'] ?? '';

    if (!contentType.contains('multipart/form-data')) {
      return shelf.Response(400, body: 'Expected multipart/form-data');
    }

    // Extract boundary from content-type header.
    final boundaryMatch =
        RegExp(r'boundary=(.+)').firstMatch(contentType);
    if (boundaryMatch == null) {
      return shelf.Response(400, body: 'Missing boundary');
    }

    final boundary = boundaryMatch.group(1)!;
    final bodyBytes = await request.read().fold<List<int>>(
      <int>[],
      (acc, chunk) => acc..addAll(chunk),
    );

    final savedFiles = <String>[];

    // Simple multipart parser — extracts file parts.
    final parts = _parseMultipart(bodyBytes, boundary);
    for (final part in parts) {
      if (part.fileName == null || part.fileName!.isEmpty) continue;

      final sanitizedName = p.basename(part.fileName!);
      if (sanitizedName.isEmpty) continue;

      final savePath = p.join(downloadPath, sanitizedName);

      // Ensure download directory exists.
      await Directory(downloadPath).create(recursive: true);

      await File(savePath).writeAsBytes(part.data);
      savedFiles.add(sanitizedName);
      _log.info('Portal: received file "$sanitizedName" '
          '(${part.data.length} bytes)');
    }

    return shelf.Response.ok(
      jsonEncode({
        'success': true,
        'files': savedFiles,
        'count': savedFiles.length,
      }),
      headers: {'Content-Type': 'application/json'},
    );
  });
}

// ---------------------------------------------------------------------------
// Simple multipart form data parser
// ---------------------------------------------------------------------------

class _MultipartPart {
  final String? fileName;
  final List<int> data;

  _MultipartPart({this.fileName, required this.data});
}

List<_MultipartPart> _parseMultipart(List<int> body, String boundary) {
  final parts = <_MultipartPart>[];
  final boundaryBytes = utf8.encode('--$boundary');

  // Find all boundary positions.
  final positions = <int>[];
  for (int i = 0; i <= body.length - boundaryBytes.length; i++) {
    bool match = true;
    for (int j = 0; j < boundaryBytes.length; j++) {
      if (body[i + j] != boundaryBytes[j]) {
        match = false;
        break;
      }
    }
    if (match) positions.add(i);
  }

  for (int p = 0; p < positions.length - 1; p++) {
    final start = positions[p] + boundaryBytes.length;
    final end = positions[p + 1];

    // Skip CRLF after boundary.
    int contentStart = start;
    while (contentStart < end && body[contentStart] == 13 || contentStart < end && body[contentStart] == 10) {
      contentStart++;
    }

    // Find header/body separator (double CRLF).
    int headerEnd = contentStart;
    for (int i = contentStart; i < end - 3; i++) {
      if (body[i] == 13 &&
          body[i + 1] == 10 &&
          body[i + 2] == 13 &&
          body[i + 3] == 10) {
        headerEnd = i;
        break;
      }
    }

    final headerStr = utf8.decode(body.sublist(contentStart, headerEnd));
    final bodyStart = headerEnd + 4;

    // Trim trailing CRLF before next boundary.
    int bodyEnd = end;
    if (bodyEnd >= 2 && body[bodyEnd - 1] == 10 && body[bodyEnd - 2] == 13) {
      bodyEnd -= 2;
    }

    if (bodyStart >= bodyEnd) continue;

    // Extract filename from Content-Disposition header.
    String? fileName;
    final fileNameMatch =
        RegExp(r'filename="([^"]*)"').firstMatch(headerStr);
    if (fileNameMatch != null) {
      fileName = fileNameMatch.group(1);
    }

    parts.add(_MultipartPart(
      fileName: fileName,
      data: body.sublist(bodyStart, bodyEnd),
    ));
  }

  return parts;
}
