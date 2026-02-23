import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:mime/mime.dart';

import 'package:anyware/core/logger.dart';

import 'package:anyware/core/constants.dart';
import 'package:anyware/features/discovery/domain/device.dart';
import 'package:anyware/features/transfer/domain/transfer.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';
import 'package:uuid/uuid.dart';

import 'package:anyware/features/sync/domain/sync_state.dart';
import 'package:anyware/features/portal/data/portal_routes.dart';

/// HTTP file-transfer server that runs on the local network.
///
/// Exposes a set of REST endpoints that allow remote devices to:
///   - Query this device's info.
///   - Request a file transfer.
///   - Upload file data for an accepted transfer.
///   - Query the status of a transfer.
///
/// Files are saved in chunked fashion so that large payloads never need to be
/// held entirely in memory.
class FileServer {
  FileServer({
    required this.localDevice,
    required this.downloadPath,
    this.overwriteFiles = false,
    this.syncReceiveFolder = '',
  });

  static final _log = AppLogger('FileServer');

  /// Info about the device running this server.
  final Device localDevice;

  /// The directory where incoming files are saved.
  String downloadPath;

  /// Whether to overwrite existing files with the same name.
  bool overwriteFiles;

  /// Custom folder for incoming sync files. When empty, defaults to
  /// `<downloadPath>/Sync/<senderName>/`.
  String syncReceiveFolder;

  HttpServer? _server;

  /// All transfers this server knows about, keyed by transfer id.
  final Map<String, Transfer> _transfers = {};

  /// Expected SHA-256 hash for each transfer (sent by the sender in the
  /// send-request). Used to verify file integrity after upload completes.
  final Map<String, String> _expectedHashes = {};

  /// Tracks how many bytes have been received per transfer for resume support.
  /// When a sender reconnects with an X-Offset header, this map (together with
  /// the temp file size) lets us validate the offset.
  final Map<String, int> _bytesReceived = {};

  /// Deduplication: maps "fileName|senderId|fileSize" → (transferId, timestamp).
  /// Prevents duplicate transfers when the sender retries the send-request.
  final Map<String, _DedupeEntry> _recentRequests = {};

  /// Timer that periodically cleans up completed/failed transfers from memory.
  Timer? _cleanupTimer;

  final Uuid _uuid = const Uuid();

  // Stream controllers --------------------------------------------------

  final StreamController<Transfer> _incomingRequestController =
      StreamController<Transfer>.broadcast();

  final StreamController<Transfer> _progressController =
      StreamController<Transfer>.broadcast();

  /// Emits a [Transfer] each time a remote device requests to send a file.
  /// The UI layer can listen to this stream and decide whether to accept or
  /// reject the transfer.
  Stream<Transfer> get incomingRequests => _incomingRequestController.stream;

  /// Emits progress updates for every active transfer (incoming).
  Stream<Transfer> get progressUpdates => _progressController.stream;

  /// Whether the server is currently listening.
  bool get isRunning => _server != null;

  /// Callback that the caller can set to decide whether to accept an incoming
  /// transfer. When `null` or when it returns `true`, transfers are accepted
  /// automatically.
  Future<bool> Function(Transfer transfer)? onTransferRequest;

  // Lifecycle -----------------------------------------------------------

  /// Starts the HTTP server on the given [port].
  Future<void> start([int port = AppConstants.defaultPort]) async {
    if (_server != null) return;

    final router = _buildRouter();
    final handler = const shelf.Pipeline()
        .addMiddleware(shelf.logRequests())
        .addHandler(router.call);

    _server = await shelf_io.serve(
      handler,
      InternetAddress.anyIPv4,
      port,
      shared: true,
    );

    // Periodically clean up finished transfers to prevent memory leaks
    // during long-running sessions.
    _cleanupTimer?.cancel();
    _cleanupTimer = Timer.periodic(
      const Duration(minutes: 10),
      (_) => _cleanupFinishedTransfers(),
    );
  }

  /// Stops the server gracefully.
  Future<void> stop() async {
    _cleanupTimer?.cancel();
    _cleanupTimer = null;
    await _server?.close(force: true);
    _server = null;
  }

  /// Stops the server and closes all stream controllers.
  Future<void> dispose() async {
    await stop();
    _transfers.clear();
    _bytesReceived.clear();
    _incomingRequestController.close();
    _progressController.close();
  }

  /// Removes transfers that finished (completed / failed / cancelled) more
  /// than 30 minutes ago. Keeps active transfers and recent completions so
  /// the UI can still display them.
  void _cleanupFinishedTransfers() {
    final now = DateTime.now();
    final staleIds = <String>[];

    for (final entry in _transfers.entries) {
      final t = entry.value;
      if (!t.isActive) {
        final age = now.difference(t.createdAt);
        if (age.inMinutes > 30) {
          staleIds.add(entry.key);
        }
      }
    }

    if (staleIds.isNotEmpty) {
      for (final id in staleIds) {
        _transfers.remove(id);
        _bytesReceived.remove(id);
        // Clean up orphaned temp files for completed/failed transfers.
        _deleteTempFile(_getTempPath(id));
      }
      _log.debug('Cleaned up ${staleIds.length} finished transfers from memory.');
    }

    // Also clean up stale deduplication entries (older than 60 seconds).
    _recentRequests.removeWhere(
      (_, entry) => now.difference(entry.timestamp).inSeconds > 60,
    );
  }

  // Routing -------------------------------------------------------------

  Router _buildRouter() {
    final router = Router();

    router.get('/api/ping', _handlePing);
    router.get('/api/info', _handleInfo);
    router.post('/api/send-request', _handleSendRequest);
    router.post('/api/upload/<transferId>', _handleUpload);
    router.get('/api/status/<transferId>', _handleStatus);
    router.post('/api/clipboard', _handleClipboard);
    router.post('/api/sync/setup-request', _handleSyncSetupRequest);
    router.post('/api/sync/upload', _handleSyncUpload);
    router.post('/api/sync/delete', _handleSyncDelete);
    router.get('/api/sync/check', _handleSyncCheck);
    router.post('/api/sync/manifest', _handleSyncManifest);
    router.get('/api/sync/pull', _handleSyncPull);
    router.post('/api/sync/remove-pairing', _handleRemovePairing);

    // Web Portal routes — browser-based file management.
    registerPortalRoutes(
      router,
      getDevice: () => localDevice,
      getDownloadPath: () => downloadPath,
    );

    return router;
  }

  /// Callback for clipboard receive events so the UI can update history.
  void Function(Map<String, dynamic> clipboardData)? onClipboardReceived;

  /// Callback for sync file receive events so the UI can update sync state.
  ///
  /// Parameters: relativePath, senderName, savedPath, senderDeviceId, fileSize,
  /// jobId (nullable), jobName (nullable).
  void Function(String relativePath, String senderName, String savedPath,
      String senderDeviceId, int fileSize,
      String? jobId, String? jobName)? onSyncFileReceived;

  /// Callback for sync setup requests (handshake protocol).
  ///
  /// Called when a remote device sends a setup request. The callback should
  /// check for existing pairings (auto-accept) or show a dialog to the user.
  /// Returns `{accepted: true, receiveFolder: "..."}` or `{accepted: false}`.
  Future<Map<String, dynamic>> Function(SyncSetupRequest request)?
      onSyncSetupRequest;

  /// Callback that returns the receive folder for a given job ID.
  ///
  /// Used by sync handlers to resolve the correct destination folder
  /// when a pairing exists. Returns `null` if no pairing is found.
  String? Function(String jobId)? getSyncReceiveFolderForJob;

  /// Callback when a remote device notifies us that a pairing/job was removed.
  void Function(String jobId, String remoteDeviceId)? onRemotePairingRemoved;

  /// POST /api/clipboard
  ///
  /// Expects a JSON body with:
  ///   - `text` (String) — text content
  ///   - `imageBase64` (String, optional) — base64-encoded image data
  ///   - `sender` (String) — sender device name
  ///   - `senderDeviceId` (String, optional) — sender device ID
  ///   - `type` (String) — 'text' or 'image'
  ///
  /// Writes the received text to the system clipboard and notifies listeners.
  Future<shelf.Response> _handleClipboard(shelf.Request request) async {
    try {
      final body = await request.readAsString();
      final json = jsonDecode(body) as Map<String, dynamic>;
      final text = json['text'] as String? ?? '';
      final type = json['type'] as String? ?? 'text';
      final imageBase64 = json['imageBase64'] as String?;

      if (type == 'text' && text.isEmpty) {
        return shelf.Response.badRequest(
          body: jsonEncode({'error': 'Text is required'}),
          headers: _jsonHeaders,
        );
      }

      // Handle text clipboard — write to system clipboard.
      // Clipboard.setData must run on the platform thread; shelf runs on the
      // main Dart isolate so this is safe, but we wrap it with a try-catch
      // to prevent platform channel errors from killing the request.
      if (type == 'text' && text.isNotEmpty) {
        try {
          await Clipboard.setData(ClipboardData(text: text));
          _log.debug('Clipboard text set (${text.length} chars) from ${json['sender']}');
        } catch (e) {
          // On some Android versions (13+) clipboard write may fail if the
          // app is in the background.  We still want to continue so the
          // history entry is created.
          _log.warning('Clipboard.setData failed (app may be in background): $e');
        }
      }

      // Handle image clipboard — save to download path.
      String? savedImagePath;
      if (type == 'image' && imageBase64 != null && imageBase64.isNotEmpty) {
        try {
          final bytes = base64Decode(imageBase64);
          final dir = Directory(downloadPath);
          if (!dir.existsSync()) {
            dir.createSync(recursive: true);
          }
          final timestamp = DateTime.now().millisecondsSinceEpoch;
          savedImagePath = p.join(downloadPath, 'clipboard_$timestamp.png');
          await File(savedImagePath).writeAsBytes(bytes);
        } catch (e) {
          _log.error('Failed to save clipboard image: $e', error: e);
        }
      }

      // Notify listeners (UI clipboard history).
      onClipboardReceived?.call({
        ...json,
        'imagePath': savedImagePath,
      });

      return shelf.Response.ok(
        jsonEncode({'status': 'copied', 'imagePath': savedImagePath}),
        headers: _jsonHeaders,
      );
    } catch (e) {
      return shelf.Response.internalServerError(
        body: jsonEncode({'error': 'Clipboard error: $e'}),
        headers: _jsonHeaders,
      );
    }
  }

  // Handlers ------------------------------------------------------------

  /// POST /api/sync/setup-request
  ///
  /// Handles a sync handshake request from a remote sender.
  /// Expects JSON body matching [SyncSetupRequest] fields.
  /// Delegates to [onSyncSetupRequest] callback which either auto-accepts
  /// (existing pairing) or shows a dialog to the user.
  Future<shelf.Response> _handleSyncSetupRequest(shelf.Request request) async {
    try {
      final body = await request.readAsString();
      final json = jsonDecode(body) as Map<String, dynamic>;

      // Inject the sender IP from the connection if not in the body.
      if (!json.containsKey('senderIp') ||
          (json['senderIp'] as String?)?.isEmpty == true) {
        final connInfo =
            request.context['shelf.io.connection_info'] as HttpConnectionInfo?;
        json['senderIp'] = connInfo?.remoteAddress.address ?? '';
      }

      final setupRequest = SyncSetupRequest.fromJson(json);

      _log.info('Received sync setup request: '
          'jobId=${setupRequest.jobId}, jobName=${setupRequest.jobName}, '
          'from=${setupRequest.senderDeviceName} (${setupRequest.senderIp})');

      if (onSyncSetupRequest == null) {
        _log.warning('onSyncSetupRequest callback is null — rejecting');
        return shelf.Response.ok(
          jsonEncode({'accepted': false, 'reason': 'No handler configured'}),
          headers: _jsonHeaders,
        );
      }

      final result = await onSyncSetupRequest!(setupRequest);
      _log.info('Setup request result for ${setupRequest.jobId}: $result');

      return shelf.Response.ok(
        jsonEncode(result),
        headers: _jsonHeaders,
      );
    } catch (e) {
      _log.error('Sync setup request error: $e', error: e);
      return shelf.Response.internalServerError(
        body: jsonEncode({'error': 'Setup request failed: $e'}),
        headers: _jsonHeaders,
      );
    }
  }

  /// POST /api/sync/upload
  ///
  /// Receives a file directly (Multipart) and saves it to the Sync directory.
  /// Preserves the relative path sent in `X-Sync-Path`.
  Future<shelf.Response> _handleSyncUpload(shelf.Request request) async {
    final contentType = request.headers['content-type'] ?? '';
    if (!contentType.contains('multipart/form-data')) {
      return shelf.Response.badRequest(body: 'Expected multipart request');
    }

    try {
      // Extract boundary from content-type header.
      // Format: multipart/form-data; boundary=----WebKitFormBoundary...
      final boundaryMatch = RegExp(r'boundary=(.+)$').firstMatch(contentType);
      if (boundaryMatch == null) {
        return shelf.Response.badRequest(body: 'Missing boundary in content-type');
      }
      var boundary = boundaryMatch.group(1)!.trim();
      // Remove surrounding quotes if present.
      if (boundary.startsWith('"') && boundary.endsWith('"')) {
        boundary = boundary.substring(1, boundary.length - 1);
      }
      final transformer = MimeMultipartTransformer(boundary);
      final parts = transformer.bind(request.read());

      final senderName = Uri.decodeFull(request.headers['X-Device-Name'] ?? 'Unknown');
      final relativePath = request.headers['X-Sync-Path'] != null
          ? Uri.decodeFull(request.headers['X-Sync-Path']!)
          : null;

      if (relativePath == null) {
        return shelf.Response.badRequest(body: 'Missing X-Sync-Path header');
      }

      // ── Job-aware headers (new protocol) ──
      final jobId = request.headers['X-Sync-Job-Id'];
      final jobName = request.headers['X-Sync-Job-Name'] != null
          ? Uri.decodeFull(request.headers['X-Sync-Job-Name']!)
          : null;

      // Resolve sync base directory via pairing or default layout.
      final syncBaseDir = _resolveSyncBaseDir(senderName, jobId, jobName);

      // Normalize and resolve path to prevent directory traversal attacks
      final targetPath = p.normalize(p.join(syncBaseDir, relativePath));

      if (!p.isWithin(syncBaseDir, targetPath)) {
        return shelf.Response.forbidden('Invalid file path');
      }

      final targetDir = p.dirname(targetPath);

      if (!Directory(targetDir).existsSync()) {
        await Directory(targetDir).create(recursive: true);
      }

      await for (final part in parts) {
        final content = part.cast<List<int>>();
        // Overwrite existing file for sync (Mirroring)
        final file = File(targetPath);
        final sink = file.openWrite();
        await sink.addStream(content);
        await sink.close();
      }

      final savedFileSize = File(targetPath).existsSync()
          ? File(targetPath).lengthSync()
          : 0;
      final senderDeviceId = request.headers['X-Device-Id'] ?? '';

      _log.info('Synced file $relativePath from $senderName '
          '(jobId: $jobId, jobName: $jobName, size: $savedFileSize, '
          'path: $targetPath)');

      if (Platform.isAndroid) {
        _scanMediaFile(targetPath);
      }

      // Notify listeners (sync UI + notifications).
      if (onSyncFileReceived != null) {
        _log.info('Firing onSyncFileReceived callback for $relativePath');
        onSyncFileReceived?.call(
          relativePath, senderName, targetPath, senderDeviceId, savedFileSize,
          jobId, jobName,
        );
      } else {
        _log.warning('onSyncFileReceived callback is NULL — '
            'sync UI will not update! File saved but UI unaware.');
      }

      return shelf.Response.ok(
        jsonEncode({'status': 'synced', 'path': targetPath}),
        headers: _jsonHeaders,
      );
    } catch (e) {
      _log.error('Sync upload error: $e', error: e);
      return shelf.Response.internalServerError(
        body: jsonEncode({'error': 'Sync upload failed: $e'}),
        headers: _jsonHeaders,
      );
    }
  }

  /// POST /api/sync/delete
  ///
  /// Receives a JSON body with the relative path of a file to delete.
  /// Used for sync mirroring when source deletes a file.
  Future<shelf.Response> _handleSyncDelete(shelf.Request request) async {
    try {
      final body = await request.readAsString();
      final json = jsonDecode(body) as Map<String, dynamic>;

      final senderName = json['senderName'] as String? ?? 'Unknown';
      final relativePath = json['relativePath'] as String?;
      final jobId = json['jobId'] as String?;
      final jobName = json['jobName'] as String?;

      if (relativePath == null || relativePath.isEmpty) {
        return shelf.Response.badRequest(
          body: jsonEncode({'error': 'Missing relativePath'}),
          headers: _jsonHeaders,
        );
      }

      final syncBaseDir = _resolveSyncBaseDir(senderName, jobId, jobName);

      final targetPath = p.normalize(p.join(syncBaseDir, relativePath));

      // Prevent directory traversal.
      if (!p.isWithin(syncBaseDir, targetPath)) {
        return shelf.Response.forbidden('Invalid file path');
      }

      final file = File(targetPath);
      if (file.existsSync()) {
        await file.delete();
        _log.info('Sync-deleted $relativePath from $senderName');
      }

      return shelf.Response.ok(
        jsonEncode({'status': 'deleted', 'path': targetPath}),
        headers: _jsonHeaders,
      );
    } catch (e) {
      _log.error('Sync delete error: $e', error: e);
      return shelf.Response.internalServerError(
        body: jsonEncode({'error': 'Sync delete failed: $e'}),
        headers: _jsonHeaders,
      );
    }
  }

  /// `GET /api/sync/check?path=relPath&sender=name`
  ///
  /// Returns file metadata (exists, size, lastModified) for smart sync.
  /// The sender queries this before uploading to decide if the file needs syncing.
  Future<shelf.Response> _handleSyncCheck(shelf.Request request) async {
    try {
      final relativePath = request.url.queryParameters['path'];
      final senderName = request.url.queryParameters['sender'] ?? 'Unknown';
      final jobId = request.url.queryParameters['jobId'];
      final jobName = request.url.queryParameters['jobName'];

      if (relativePath == null || relativePath.isEmpty) {
        return shelf.Response.badRequest(
          body: jsonEncode({'error': 'Missing path parameter'}),
          headers: _jsonHeaders,
        );
      }

      final syncBaseDir = _resolveSyncBaseDir(senderName, jobId, jobName);

      final targetPath = p.normalize(p.join(syncBaseDir, relativePath));

      // Prevent directory traversal.
      if (!p.isWithin(syncBaseDir, targetPath)) {
        return shelf.Response.forbidden('Invalid file path');
      }

      final file = File(targetPath);
      if (!file.existsSync()) {
        return shelf.Response.ok(
          jsonEncode({'exists': false}),
          headers: _jsonHeaders,
        );
      }

      final stat = file.statSync();
      return shelf.Response.ok(
        jsonEncode({
          'exists': true,
          'size': stat.size,
          'lastModified': stat.modified.toIso8601String(),
        }),
        headers: _jsonHeaders,
      );
    } catch (e) {
      _log.error('Sync check error: $e', error: e);
      return shelf.Response.internalServerError(
        body: jsonEncode({'error': 'Sync check failed: $e'}),
        headers: _jsonHeaders,
      );
    }
  }

  /// POST /api/sync/manifest
  ///
  /// Returns the file manifest for a given sync directory.
  /// Expects JSON body with:
  ///   - `basePath` (String) — relative sync path (e.g. "Sync/DeviceName")
  ///   - `senderName` (String) — name of the requesting device
  ///
  /// Scans the directory and returns a JSON manifest with all file entries.
  Future<shelf.Response> _handleSyncManifest(shelf.Request request) async {
    try {
      final body = await request.readAsString();
      final json = jsonDecode(body) as Map<String, dynamic>;

      final basePath = json['basePath'] as String? ?? '';
      final senderName = json['senderName'] as String? ?? 'Unknown';
      final jobId = json['jobId'] as String?;
      final jobName = json['jobName'] as String?;

      // Determine the scan directory.
      // If basePath is provided, it's relative to downloadPath.
      // Otherwise resolve via pairing or default sync folder.
      String scanDir;
      if (basePath.isNotEmpty) {
        scanDir = p.normalize(p.join(downloadPath, basePath));
        if (!p.isWithin(downloadPath, scanDir) && scanDir != downloadPath) {
          return shelf.Response.forbidden('Invalid base path');
        }
      } else {
        scanDir = _resolveSyncBaseDir(senderName, jobId, jobName);
      }

      final dir = Directory(scanDir);
      if (!dir.existsSync()) {
        // No sync directory yet — return empty manifest.
        return shelf.Response.ok(
          jsonEncode({
            'deviceId': localDevice.id,
            'basePath': scanDir,
            'createdAt': DateTime.now().toUtc().toIso8601String(),
            'entries': <Map<String, dynamic>>[],
          }),
          headers: _jsonHeaders,
        );
      }

      final entries = <Map<String, dynamic>>[];
      final entities = dir.listSync(recursive: true);
      for (final entity in entities) {
        if (entity is File) {
          final relPath = p.relative(entity.path, from: scanDir)
              .replaceAll(r'\', '/');
          try {
            final stat = entity.statSync();
            entries.add({
              'relativePath': relPath,
              'size': stat.size,
              'lastModified': stat.modified.toUtc().toIso8601String(),
            });
          } catch (e) {
            _log.warning('Manifest scan: cannot stat $relPath: $e');
          }
        }
      }

      return shelf.Response.ok(
        jsonEncode({
          'deviceId': localDevice.id,
          'basePath': scanDir,
          'createdAt': DateTime.now().toUtc().toIso8601String(),
          'entries': entries,
        }),
        headers: _jsonHeaders,
      );
    } catch (e) {
      _log.error('Sync manifest error: $e', error: e);
      return shelf.Response.internalServerError(
        body: jsonEncode({'error': 'Sync manifest failed: $e'}),
        headers: _jsonHeaders,
      );
    }
  }

  /// `GET /api/sync/pull?path=relativePath&sender=name&basePath=optional`
  ///
  /// Streams the requested file back to the caller (for bidirectional pull).
  /// The caller provides a relative path and the sender name to locate the
  /// file within the sync directory.
  Future<shelf.Response> _handleSyncPull(shelf.Request request) async {
    try {
      final relativePath = request.url.queryParameters['path'];
      final senderName = request.url.queryParameters['sender'] ?? 'Unknown';
      final basePath = request.url.queryParameters['basePath'];
      final jobId = request.url.queryParameters['jobId'];
      final jobName = request.url.queryParameters['jobName'];

      if (relativePath == null || relativePath.isEmpty) {
        return shelf.Response.badRequest(
          body: jsonEncode({'error': 'Missing path parameter'}),
          headers: _jsonHeaders,
        );
      }

      // Determine base directory.
      String baseDir;
      if (basePath != null && basePath.isNotEmpty) {
        baseDir = p.normalize(p.join(downloadPath, basePath));
        if (!p.isWithin(downloadPath, baseDir) && baseDir != downloadPath) {
          return shelf.Response.forbidden('Invalid base path');
        }
      } else {
        baseDir = _resolveSyncBaseDir(senderName, jobId, jobName);
      }

      final filePath = p.normalize(p.join(baseDir, relativePath));

      // Prevent directory traversal.
      if (!p.isWithin(baseDir, filePath)) {
        return shelf.Response.forbidden('Invalid file path');
      }

      final file = File(filePath);
      if (!file.existsSync()) {
        return shelf.Response.notFound(
          jsonEncode({'error': 'File not found: $relativePath'}),
          headers: _jsonHeaders,
        );
      }

      final stat = file.statSync();
      final mimeType = lookupMimeType(filePath) ?? 'application/octet-stream';

      return shelf.Response.ok(
        file.openRead(),
        headers: {
          'Content-Type': mimeType,
          'Content-Length': stat.size.toString(),
          'X-Last-Modified': stat.modified.toUtc().toIso8601String(),
          'Content-Disposition':
              'attachment; filename="${Uri.encodeComponent(p.basename(filePath))}"',
        },
      );
    } catch (e) {
      _log.error('Sync pull error: $e', error: e);
      return shelf.Response.internalServerError(
        body: jsonEncode({'error': 'Sync pull failed: $e'}),
        headers: _jsonHeaders,
      );
    }
  }

  /// POST /api/sync/remove-pairing
  ///
  /// Notifies this device that the remote side has removed a sync pairing/job.
  /// Body: `{ "jobId": "...", "senderDeviceId": "..." }`
  Future<shelf.Response> _handleRemovePairing(shelf.Request request) async {
    try {
      final bodyStr = await request.readAsString();
      final body = jsonDecode(bodyStr) as Map<String, dynamic>;

      final jobId = body['jobId'] as String? ?? '';
      final remoteDeviceId = body['senderDeviceId'] as String? ?? '';

      if (jobId.isEmpty) {
        return shelf.Response.badRequest(
          body: jsonEncode({'error': 'Missing jobId'}),
          headers: _jsonHeaders,
        );
      }

      _log.info('Remote pairing removal received: jobId=$jobId, '
          'from=$remoteDeviceId');

      onRemotePairingRemoved?.call(jobId, remoteDeviceId);

      return shelf.Response.ok(
        jsonEncode({'removed': true}),
        headers: _jsonHeaders,
      );
    } catch (e) {
      _log.error('Remove pairing error: $e', error: e);
      return shelf.Response.internalServerError(
        body: jsonEncode({'error': 'Failed: $e'}),
        headers: _jsonHeaders,
      );
    }
  }

  /// GET /api/ping
  ///
  /// Lightweight health check endpoint. Returns immediately with a simple OK.
  Future<shelf.Response> _handlePing(shelf.Request request) async {
    return shelf.Response.ok(
      jsonEncode({'status': 'ok', 'timestamp': DateTime.now().toIso8601String()}),
      headers: _jsonHeaders,
    );
  }

  /// GET /api/info
  ///
  /// Returns the local device info as JSON.
  Future<shelf.Response> _handleInfo(shelf.Request request) async {
    return shelf.Response.ok(
      jsonEncode(localDevice.toJson()),
      headers: _jsonHeaders,
    );
  }

  /// POST /api/send-request
  ///
  /// Expects a JSON body with:
  ///   - `fileName` (String)
  ///   - `fileSize` (int)
  ///   - `senderId` (String)
  ///   - `senderName` (String)
  ///
  /// Creates a pending [Transfer], notifies listeners, and returns whether the
  /// transfer was accepted along with a `transferId`.
  Future<shelf.Response> _handleSendRequest(shelf.Request request) async {
    try {
      final body = await request.readAsString();
      final json = jsonDecode(body) as Map<String, dynamic>;

      final fileName = json['fileName'] as String;
      final fileSize = json['fileSize'] as int;
      final senderId = json['senderId'] as String;
      final senderName = json['senderName'] as String;
      final senderIp = json['senderIp'] as String? ??
          (request.context['shelf.io.connection_info'] as HttpConnectionInfo?)
              ?.remoteAddress
              .address ??
          '';
      final senderPort =
          json['senderPort'] as int? ?? AppConstants.defaultPort;
      final senderPlatform = json['senderPlatform'] as String? ?? '';
      final senderVersion =
          json['senderVersion'] as String? ?? AppConstants.protocolVersion;

      // Deduplication: if the same file from the same sender was requested
      // recently AND the transfer is still active (pending/accepted/transferring),
      // return the existing transferId to avoid duplicate entries.
      // If the previous transfer already completed or failed, allow a fresh one.
      final dedupeKey = '$fileName|$senderId|$fileSize';
      final existing = _recentRequests[dedupeKey];
      if (existing != null &&
          DateTime.now().difference(existing.timestamp).inSeconds < 30) {
        final existingTransfer = _transfers[existing.transferId];
        if (existingTransfer != null && existingTransfer.isActive) {
          _log.info(
            'Duplicate send-request for "$fileName" from $senderId — '
            'returning existing transferId ${existing.transferId}',
          );
          return shelf.Response.ok(
            jsonEncode({
              'accepted': existingTransfer.status != TransferStatus.rejected,
              'transferId': existing.transferId,
            }),
            headers: _jsonHeaders,
          );
        }
      }

      final transferId = _uuid.v4();
      _recentRequests[dedupeKey] = _DedupeEntry(transferId, DateTime.now());

      // Store expected SHA-256 hash for integrity verification after upload.
      final expectedHash = json['sha256'] as String?;
      if (expectedHash != null && expectedHash.isNotEmpty) {
        _expectedHashes[transferId] = expectedHash;
      }

      final senderDevice = Device(
        id: senderId,
        name: senderName,
        ip: senderIp,
        port: senderPort,
        platform: senderPlatform,
        version: senderVersion,
        lastSeen: DateTime.now(),
      );

      final transfer = Transfer(
        id: transferId,
        fileName: fileName,
        fileSize: fileSize,
        senderDevice: senderDevice,
        receiverDevice: localDevice,
        status: TransferStatus.pending,
        createdAt: DateTime.now(),
      );

      _transfers[transferId] = transfer;

      // Notify listeners about the incoming request.
      if (!_incomingRequestController.isClosed) {
        _incomingRequestController.add(transfer);
      }

      // Decide acceptance. Apply a 60-second timeout so the sender does not
      // hang indefinitely when the receiver doesn't respond to the dialog.
      bool accepted = true;
      if (onTransferRequest != null) {
        try {
          accepted = await onTransferRequest!(transfer).timeout(
            const Duration(seconds: 60),
            onTimeout: () {
              _log.warning('Transfer request timed out after 60s — auto-rejecting');
              return false;
            },
          );
        } catch (_) {
          accepted = false;
        }
      }

      if (accepted) {
        _transfers[transferId] =
            transfer.copyWith(status: TransferStatus.accepted);
        _emitProgress(transferId);
      } else {
        _transfers[transferId] =
            transfer.copyWith(status: TransferStatus.rejected);
        _emitProgress(transferId);
      }

      return shelf.Response.ok(
        jsonEncode({
          'accepted': accepted,
          'transferId': transferId,
        }),
        headers: _jsonHeaders,
      );
    } catch (e) {
      return shelf.Response.badRequest(
        body: jsonEncode({'error': 'Invalid request: $e'}),
        headers: _jsonHeaders,
      );
    }
  }

  /// POST /api/upload/:transferId
  ///
  /// Receives the raw file bytes as a stream and writes them to the download
  /// directory. Progress updates are emitted via [progressUpdates].
  Future<shelf.Response> _handleUpload(
    shelf.Request request,
    String transferId,
  ) async {
    final transfer = _transfers[transferId];
    if (transfer == null) {
      return shelf.Response.notFound(
        jsonEncode({'error': 'Transfer not found'}),
        headers: _jsonHeaders,
      );
    }

    // Reject upload only if the transfer was explicitly rejected or cancelled.
    // All other states are allowed: accepted (normal), pending (race),
    // transferring (retry), completed (re-send same file), failed (retry).
    if (transfer.status == TransferStatus.rejected ||
        transfer.status == TransferStatus.cancelled) {
      return shelf.Response.forbidden(
        jsonEncode({'error': 'Transfer not accepted'}),
        headers: _jsonHeaders,
      );
    }

    // Mark as transferring.
    _transfers[transferId] =
        transfer.copyWith(status: TransferStatus.transferring);
    _emitProgress(transferId);

    // Use a temporary file during transfer; rename on success, delete on failure.
    String? tempPath;
    String? savePath;

    try {
      // Ensure the download directory exists.
      final dir = Directory(downloadPath);
      if (!dir.existsSync()) {
        dir.createSync(recursive: true);
      }

      // Determine the save path. For folder transfers the fileName contains
      // a relative path (e.g. "MyProject/src/main.dart") — subdirectories
      // are created as needed and the structure is preserved.
      savePath = _resolveFilePath(downloadPath, transfer.fileName);
      tempPath = _getTempPath(transferId);
      final tempFile = File(tempPath);

      // --- Resume support ---
      // The sender can include an X-Offset header indicating how many bytes
      // were already written in a previous attempt. If the temp file exists
      // and its size matches the offset, we append; otherwise we start fresh.
      final offsetHeader = request.headers['x-offset'];
      int resumeOffset = 0;
      FileMode fileMode = FileMode.write; // default: overwrite (fresh start)

      if (offsetHeader != null) {
        resumeOffset = int.tryParse(offsetHeader) ?? 0;
      }

      if (resumeOffset > 0 && tempFile.existsSync()) {
        final existingSize = tempFile.lengthSync();
        if (existingSize == resumeOffset) {
          // Temp file matches the claimed offset — append.
          fileMode = FileMode.append;
          _log.info(
            'Resuming transfer $transferId from offset $resumeOffset '
            '(temp file: $existingSize bytes)',
          );
        } else {
          // Mismatch — start fresh to avoid corruption.
          _log.warning(
            'Offset mismatch for $transferId: header=$resumeOffset, '
            'tempFile=$existingSize — restarting from zero',
          );
          resumeOffset = 0;
        }
      } else {
        resumeOffset = 0;
      }

      final sink = tempFile.openWrite(mode: fileMode);

      int bytesReceived = resumeOffset;
      _bytesReceived[transferId] = bytesReceived;
      final totalSize = transfer.fileSize;

      // Stream in chunks — the shelf request body is already a byte stream.
      await for (final chunk in request.read()) {
        sink.add(chunk);
        bytesReceived += chunk.length;
        _bytesReceived[transferId] = bytesReceived;

        final progress =
            totalSize > 0 ? (bytesReceived / totalSize).clamp(0.0, 1.0) : 0.0;
        _transfers[transferId] = _transfers[transferId]!.copyWith(
          progress: progress,
          filePath: savePath,
        );
        _emitProgress(transferId);
      }

      await sink.flush();
      await sink.close();

      // Verify received size matches expected size.
      // On resume, bytesReceived already includes the offset portion.
      if (totalSize > 0 && bytesReceived != totalSize) {
        // Don't delete the temp file — it can be resumed later.
        _transfers[transferId] = _transfers[transferId]!.copyWith(
          status: TransferStatus.failed,
          error: 'Incomplete transfer: received $bytesReceived of $totalSize bytes',
        );
        _emitProgress(transferId);
        return shelf.Response.internalServerError(
          body: jsonEncode({
            'error': 'Incomplete transfer',
            'bytesReceived': bytesReceived,
          }),
          headers: _jsonHeaders,
        );
      }

      // Atomic rename: temp file → final path.
      // On Android with Scoped Storage, rename across directories may fail.
      // Fall back to copy + delete in that case.
      try {
        await tempFile.rename(savePath);
      } catch (_) {
        await tempFile.copy(savePath);
        await tempFile.delete();
      }

      // Verify file integrity if the sender provided a SHA-256 hash.
      final expectedHash = _expectedHashes.remove(transferId);
      String? actualHash;
      if (expectedHash != null) {
        try {
          final savedFile = File(savePath);
          final digest = await sha256.bind(savedFile.openRead()).last;
          actualHash = digest.toString();
          if (actualHash != expectedHash) {
            _log.error(
              'SHA-256 mismatch for $transferId: '
              'expected=$expectedHash, actual=$actualHash',
            );
            await savedFile.delete();
            _transfers[transferId] = _transfers[transferId]!.copyWith(
              status: TransferStatus.failed,
              error: 'File integrity check failed (SHA-256 mismatch)',
            );
            _emitProgress(transferId);
            return shelf.Response.internalServerError(
              body: jsonEncode({'error': 'Integrity check failed'}),
              headers: _jsonHeaders,
            );
          }
          _log.info('SHA-256 verified for $transferId');
        } catch (e) {
          _log.warning('Could not verify SHA-256 for $transferId: $e');
        }
      }

      // Notify Android's MediaScanner so the file appears in file managers.
      if (Platform.isAndroid) {
        _scanMediaFile(savePath);
      }

      _transfers[transferId] = _transfers[transferId]!.copyWith(
        status: TransferStatus.completed,
        progress: 1.0,
        filePath: savePath,
      );
      _emitProgress(transferId);

      return shelf.Response.ok(
        jsonEncode({
          'status': 'completed',
          'transferId': transferId,
          'savePath': savePath,
        }),
        headers: _jsonHeaders,
      );
    } catch (e) {
      // Clean up incomplete temp file on failure.
      if (tempPath != null) {
        await _deleteTempFile(tempPath);
      }

      _transfers[transferId] = _transfers[transferId]!.copyWith(
        status: TransferStatus.failed,
        error: e.toString(),
      );
      _emitProgress(transferId);

      return shelf.Response.internalServerError(
        body: jsonEncode({'error': 'Upload failed: $e'}),
        headers: _jsonHeaders,
      );
    }
  }

  /// GET /api/status/:transferId
  ///
  /// Returns the current status of the given transfer as JSON.
  Future<shelf.Response> _handleStatus(
    shelf.Request request,
    String transferId,
  ) async {
    final transfer = _transfers[transferId];
    if (transfer == null) {
      return shelf.Response.notFound(
        jsonEncode({'error': 'Transfer not found'}),
        headers: _jsonHeaders,
      );
    }

    // Include resume info so the sender can query how many bytes were received
    // and decide whether to resume or restart.
    final json = transfer.toJson();
    json['bytesReceived'] = _bytesReceived[transferId] ?? 0;

    // Check temp file on disk for authoritative byte count.
    final tempPath = _getTempPath(transferId);
    final tempFile = File(tempPath);
    if (tempFile.existsSync()) {
      json['tempFileSize'] = tempFile.lengthSync();
    } else {
      json['tempFileSize'] = 0;
    }

    return shelf.Response.ok(
      jsonEncode(json),
      headers: _jsonHeaders,
    );
  }

  // Helpers -------------------------------------------------------------

  /// Resolves the sync base directory for a given request.
  ///
  /// Priority:
  /// 1. If [jobId] is non-null and [getSyncReceiveFolderForJob] returns a
  ///    folder → use that pairing folder directly.
  /// 2. Otherwise fall back to the default layout:
  ///    `<syncReceiveFolder>/<senderName>/<jobName>/`
  String _resolveSyncBaseDir(String senderName, String? jobId, String? jobName) {
    // 1) Pairing-based resolution.
    if (jobId != null && jobId.isNotEmpty && getSyncReceiveFolderForJob != null) {
      final pairingFolder = getSyncReceiveFolderForJob!(jobId);
      if (pairingFolder != null && pairingFolder.isNotEmpty) {
        return pairingFolder;
      }
    }

    // 2) Default layout.
    final senderDir = syncReceiveFolder.isNotEmpty
        ? p.join(syncReceiveFolder, senderName)
        : p.join(downloadPath, 'Sync', senderName);

    if (jobName != null && jobName.isNotEmpty) {
      return p.join(senderDir, _sanitizeDirectoryName(jobName));
    }
    return senderDir;
  }

  /// Returns the deterministic temp file path for a given transfer id.
  String _getTempPath(String transferId) {
    return p.join(Directory.systemTemp.path, '$transferId.lifeos_tmp');
  }

  /// Emits the latest state of the given transfer on [progressUpdates].
  void _emitProgress(String transferId) {
    final transfer = _transfers[transferId];
    if (transfer != null && !_progressController.isClosed) {
      _progressController.add(transfer);
    }
  }

  /// Safely deletes a temporary file, ignoring errors if it doesn't exist.
  Future<void> _deleteTempFile(String path) async {
    try {
      final f = File(path);
      if (f.existsSync()) {
        await f.delete();
        _log.debug('Cleaned up temp file: $path');
      }
    } catch (e) {
      _log.warning('Failed to delete temp file $path: $e');
    }
  }

  /// Resolves the final save path for a transfer.
  ///
  /// If [fileName] contains path separators (i.e. it is a relative path from
  /// a folder transfer like "MyProject/src/main.dart"), subdirectories are
  /// created and the full structure is preserved. For folder transfers files
  /// are always overwritten to mirror the source.
  ///
  /// For plain file names (single-file transfer), delegates to [_uniqueFilePath].
  String _resolveFilePath(String baseDir, String fileName) {
    // Normalize separators (sender may be on a different OS).
    final normalized = fileName.replaceAll(r'\', '/');

    if (normalized.contains('/')) {
      // Folder transfer — fileName is a relative path.
      final targetPath = p.normalize(p.join(baseDir, normalized));

      // Security: prevent directory traversal attacks.
      if (!p.isWithin(baseDir, targetPath)) {
        _log.warning('Blocked directory traversal attempt: $fileName');
        return _uniqueFilePath(baseDir, p.basename(fileName));
      }

      // Create intermediate directories.
      final targetDir = p.dirname(targetPath);
      final dir = Directory(targetDir);
      if (!dir.existsSync()) {
        dir.createSync(recursive: true);
      }

      return targetPath;
    }

    // Single-file transfer — use the existing collision-avoiding logic.
    return _uniqueFilePath(baseDir, fileName);
  }

  /// Returns a file path inside [directory] for [fileName].
  ///
  /// When [overwriteFiles] is `true`, returns the path directly (overwriting
  /// any existing file). Otherwise, if `photo.jpg` already exists it tries
  /// `photo (1).jpg`, `photo (2).jpg`, etc.
  String _uniqueFilePath(String directory, String fileName) {
    final candidate = p.join(directory, fileName);

    if (overwriteFiles) {
      return candidate;
    }

    if (!File(candidate).existsSync()) {
      return candidate;
    }

    final base = p.basenameWithoutExtension(fileName);
    final ext = p.extension(fileName);
    var counter = 1;
    var result = p.join(directory, '$base ($counter)$ext');

    while (File(result).existsSync()) {
      counter++;
      result = p.join(directory, '$base ($counter)$ext');
    }

    return result;
  }

  /// Triggers Android's MediaScanner so newly saved files appear in file
  /// managers, gallery, etc.
  void _scanMediaFile(String path) {
    try {
      const platform = MethodChannel('com.lifeos.anyware/platform');
      platform.invokeMethod('scanFile', {'path': path});
    } catch (e) {
      _log.warning('MediaScanner failed for $path: $e');
    }
  }

  /// Sanitizes a string for use as a directory name by removing or replacing
  /// characters that are invalid on common file systems (Windows, macOS, Linux).
  static String _sanitizeDirectoryName(String name) {
    // Replace characters invalid in Windows/macOS/Linux file names.
    var sanitized = name.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');
    // Collapse multiple underscores.
    sanitized = sanitized.replaceAll(RegExp(r'_+'), '_');
    // Trim leading/trailing whitespace and dots (Windows restriction).
    sanitized = sanitized.trim().replaceAll(RegExp(r'^[.\s]+|[.\s]+$'), '');
    // Fallback if the name is empty after sanitization.
    if (sanitized.isEmpty) sanitized = 'sync';
    return sanitized;
  }

  static const Map<String, String> _jsonHeaders = {
    'Content-Type': 'application/json',
  };
}

/// Internal helper for send-request deduplication.
class _DedupeEntry {
  _DedupeEntry(this.transferId, this.timestamp);
  final String transferId;
  final DateTime timestamp;
}
