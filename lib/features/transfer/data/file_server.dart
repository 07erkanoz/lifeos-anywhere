import 'dart:async';
import 'dart:convert';
import 'dart:io';

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
  });

  static final _log = AppLogger('FileServer');

  /// Info about the device running this server.
  final Device localDevice;

  /// The directory where incoming files are saved.
  String downloadPath;

  /// Whether to overwrite existing files with the same name.
  bool overwriteFiles;

  HttpServer? _server;

  /// All transfers this server knows about, keyed by transfer id.
  final Map<String, Transfer> _transfers = {};

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
  }

  /// Stops the server gracefully.
  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  /// Stops the server and closes all stream controllers.
  Future<void> dispose() async {
    await stop();
    _transfers.clear();
    _incomingRequestController.close();
    _progressController.close();
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
    router.post('/api/sync/upload', _handleSyncUpload);
    router.post('/api/sync/delete', _handleSyncDelete);

    return router;
  }

  /// Callback for clipboard receive events so the UI can update history.
  void Function(Map<String, dynamic> clipboardData)? onClipboardReceived;

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

      // Handle text clipboard.
      if (type == 'text' && text.isNotEmpty) {
        await Clipboard.setData(ClipboardData(text: text));
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

  /// POST /api/sync/upload
  ///
  /// Receives a file directly (Multipart) and saves it to the Sync directory.
  /// Preserves the relative path sent in `X-Sync-Path`.
  Future<shelf.Response> _handleSyncUpload(shelf.Request request) async {
    if (request.mimeType == null || !request.mimeType!.startsWith('multipart/form-data')) {
      return shelf.Response.badRequest(body: 'Expected multipart request');
    }

    try {
      final boundary = request.mimeType!.split('boundary=')[1];
      final transformer = MimeMultipartTransformer(boundary);
      final parts = transformer.bind(request.read());

      final senderName = request.headers['X-Device-Name'] ?? 'Unknown';
      final relativePath = request.headers['X-Sync-Path'];

      if (relativePath == null) {
        return shelf.Response.badRequest(body: 'Missing X-Sync-Path header');
      }

      // Create sync directory for this device: Downloads/LifeOS/Sync/<DeviceName>/
      final syncBaseDir = p.join(downloadPath, 'Sync', senderName);
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

      _log.info('Synced file $relativePath from $senderName');

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

      if (relativePath == null || relativePath.isEmpty) {
        return shelf.Response.badRequest(
          body: jsonEncode({'error': 'Missing relativePath'}),
          headers: _jsonHeaders,
        );
      }

      final syncBaseDir = p.join(downloadPath, 'Sync', senderName);
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

      final transferId = _uuid.v4();

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

      // Decide acceptance.
      bool accepted = true;
      if (onTransferRequest != null) {
        try {
          accepted = await onTransferRequest!(transfer);
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

    if (transfer.status != TransferStatus.accepted) {
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

      // Determine a non-colliding file path.
      savePath = _uniqueFilePath(downloadPath, transfer.fileName);
      tempPath = '$savePath.lifeos_tmp';
      final tempFile = File(tempPath);
      final sink = tempFile.openWrite();

      int bytesReceived = 0;
      final totalSize = transfer.fileSize;

      // Stream in chunks — the shelf request body is already a byte stream.
      await for (final chunk in request.read()) {
        sink.add(chunk);
        bytesReceived += chunk.length;

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
      if (totalSize > 0 && bytesReceived != totalSize) {
        await _deleteTempFile(tempPath);
        _transfers[transferId] = _transfers[transferId]!.copyWith(
          status: TransferStatus.failed,
          error: 'Incomplete transfer: received $bytesReceived of $totalSize bytes',
        );
        _emitProgress(transferId);
        return shelf.Response.internalServerError(
          body: jsonEncode({'error': 'Incomplete transfer'}),
          headers: _jsonHeaders,
        );
      }

      // Atomic rename: temp file → final path.
      await tempFile.rename(savePath);

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

    return shelf.Response.ok(
      jsonEncode(transfer.toJson()),
      headers: _jsonHeaders,
    );
  }

  // Helpers -------------------------------------------------------------

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

  static const Map<String, String> _jsonHeaders = {
    'Content-Type': 'application/json',
  };
}
