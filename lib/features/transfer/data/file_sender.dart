import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:anyware/core/logger.dart';
import 'package:anyware/features/discovery/domain/device.dart';
import 'package:anyware/features/transfer/domain/transfer.dart';

/// Client-side service that sends files to other devices on the network.
///
/// Includes HTTP timeouts, automatic retry with exponential backoff,
/// and chunked streaming for large file transfer resilience.
class FileSender {
  FileSender({required this.localDevice});

  static final _log = AppLogger('FileSender');

  /// The device info representing this machine (the sender).
  final Device localDevice;

  /// Maximum upload speed in KB/s. 0 = unlimited.
  int maxUploadSpeedKBps = 0;

  late final HttpClient _httpClient = HttpClient()
    ..connectionTimeout = const Duration(seconds: 30)
    ..idleTimeout = const Duration(seconds: 60);

  /// Active client request that can be aborted for cancellation.
  HttpClientRequest? _activeRequest;

  /// Whether a cancellation has been requested for the current transfer.
  bool _cancelRequested = false;

  /// Maximum number of retry attempts for failed transfers.
  static const int _maxRetries = 3;

  /// Base delay for exponential backoff (doubles each attempt).
  static const Duration _baseRetryDelay = Duration(seconds: 1);

  /// Timeout for the entire upload response after streaming completes.
  static const Duration _responseTimeout = Duration(minutes: 5);

  final StreamController<Transfer> _progressController =
      StreamController<Transfer>.broadcast();

  /// A broadcast stream that emits [Transfer] objects whenever a send
  /// operation makes progress or changes status.
  Stream<Transfer> get progressUpdates => _progressController.stream;

  /// Sends a file at [filePath] to the [target] device.
  ///
  /// Includes automatic retry with exponential backoff (up to 3 attempts).
  /// Large files are streamed in chunks to avoid memory issues and support
  /// connection resilience.
  Future<Transfer> sendFile(Device target, String filePath) async {
    _cancelRequested = false;
    _activeRequest = null;

    final file = File(filePath);
    if (!file.existsSync()) {
      throw FileSystemException('File not found', filePath);
    }

    final fileName = file.uri.pathSegments.last;
    final fileSize = await file.length();

    Transfer transfer = Transfer(
      id: '',
      fileName: fileName,
      fileSize: fileSize,
      senderDevice: localDevice,
      receiverDevice: target,
      status: TransferStatus.pending,
      createdAt: DateTime.now(),
    );
    _emitProgress(transfer);

    // ------------------------------------------------------------------
    // Step 0: Verify the target device is reachable.
    // ------------------------------------------------------------------
    final isReachable = await pingDevice(target);
    if (!isReachable) {
      transfer = transfer.copyWith(
        status: TransferStatus.failed,
        error: 'Device is not reachable',
      );
      _emitProgress(transfer);
      return transfer;
    }

    // ------------------------------------------------------------------
    // Step 1: Request permission from the receiver (with retry).
    // ------------------------------------------------------------------
    final requestBody = jsonEncode({
      'fileName': fileName,
      'fileSize': fileSize,
      'senderId': localDevice.id,
      'senderName': localDevice.name,
      'senderIp': localDevice.ip,
      'senderPort': localDevice.port,
      'senderPlatform': localDevice.platform,
      'senderVersion': localDevice.version,
    });

    final requestUri = Uri.http(
      '${target.ip}:${target.port}',
      '/api/send-request',
    );

    String reqResponse;
    try {
      reqResponse = await _postWithRetry(requestUri, requestBody);
    } catch (e) {
      transfer = transfer.copyWith(
        status: TransferStatus.failed,
        error: 'Could not reach device: $e',
      );
      _emitProgress(transfer);
      return transfer;
    }

    final reqJson = jsonDecode(reqResponse) as Map<String, dynamic>;
    final accepted = reqJson['accepted'] as bool? ?? false;
    final transferId = reqJson['transferId'] as String? ?? '';

    transfer = transfer.copyWith(id: transferId);

    if (!accepted) {
      transfer = transfer.copyWith(status: TransferStatus.rejected);
      _emitProgress(transfer);
      return transfer;
    }

    transfer = transfer.copyWith(status: TransferStatus.accepted);
    _emitProgress(transfer);

    // ------------------------------------------------------------------
    // Step 2: Stream the file data (with retry on network failure).
    // ------------------------------------------------------------------
    if (_cancelRequested) {
      transfer = transfer.copyWith(status: TransferStatus.cancelled);
      _emitProgress(transfer);
      return transfer;
    }

    transfer = transfer.copyWith(status: TransferStatus.transferring);
    _emitProgress(transfer);

    Transfer? uploadResult;
    for (int attempt = 1; attempt <= _maxRetries; attempt++) {
      if (_cancelRequested) {
        transfer = transfer.copyWith(status: TransferStatus.cancelled);
        _emitProgress(transfer);
        return transfer;
      }

      uploadResult = await _attemptUpload(
        target: target,
        transferId: transferId,
        file: file,
        fileSize: fileSize,
        transfer: transfer,
      );

      if (uploadResult.status == TransferStatus.completed ||
          uploadResult.status == TransferStatus.cancelled) {
        return uploadResult;
      }

      // Don't retry on 4xx errors (client errors, rejected, etc.)
      if (uploadResult.error != null &&
          uploadResult.error!.contains('Server responded with 4')) {
        _emitProgress(uploadResult);
        return uploadResult;
      }

      if (attempt < _maxRetries && !_cancelRequested) {
        final delay = _baseRetryDelay * (1 << (attempt - 1));
        _log.warning(
          'Upload attempt $attempt failed, retrying in ${delay.inSeconds}s...',
        );
        transfer = transfer.copyWith(
          error: 'Retry $attempt/$_maxRetries...',
        );
        _emitProgress(transfer);
        await Future<void>.delayed(delay);
      }
    }

    _emitProgress(uploadResult!);
    return uploadResult;
  }

  /// Attempts a single upload of the file to the target device.
  Future<Transfer> _attemptUpload({
    required Device target,
    required String transferId,
    required File file,
    required int fileSize,
    required Transfer transfer,
  }) async {
    try {
      final uploadUri = Uri.http(
        '${target.ip}:${target.port}',
        '/api/upload/$transferId',
      );

      final uploadRequest = await _httpClient.postUrl(uploadUri);
      _activeRequest = uploadRequest;

      uploadRequest.headers
        ..contentType = ContentType.binary
        ..contentLength = fileSize;

      // Stream the file in chunks with optional speed throttling.
      int bytesSent = 0;
      DateTime lastProgressTime = DateTime.now();
      int throttleBytesSent = 0;
      DateTime throttleWindowStart = DateTime.now();

      await for (final chunk in file.openRead()) {
        if (_cancelRequested) {
          uploadRequest.abort();
          return transfer.copyWith(status: TransferStatus.cancelled);
        }

        uploadRequest.add(chunk);
        bytesSent += chunk.length;
        throttleBytesSent += chunk.length;

        // Throttle: if speed limit is set, wait to stay under the limit.
        if (maxUploadSpeedKBps > 0) {
          final maxBytesPerSec = maxUploadSpeedKBps * 1024;
          final windowElapsed =
              DateTime.now().difference(throttleWindowStart).inMilliseconds;
          if (windowElapsed > 0) {
            final currentRate = (throttleBytesSent / windowElapsed) * 1000;
            if (currentRate > maxBytesPerSec) {
              final sleepMs =
                  ((throttleBytesSent / maxBytesPerSec) * 1000 - windowElapsed)
                      .ceil();
              if (sleepMs > 0) {
                await Future<void>.delayed(Duration(milliseconds: sleepMs));
              }
            }
          }
          // Reset throttle window every second.
          if (DateTime.now().difference(throttleWindowStart).inSeconds >= 1) {
            throttleBytesSent = 0;
            throttleWindowStart = DateTime.now();
          }
        }

        final now = DateTime.now();
        final progress =
            fileSize > 0 ? (bytesSent / fileSize).clamp(0.0, 1.0) : 0.0;

        // Calculate speed (bytes per second).
        final elapsed = now.difference(lastProgressTime).inMilliseconds;
        double? speed;
        Duration? eta;
        if (elapsed > 0) {
          speed = (chunk.length / elapsed) * 1000;
          final remaining = fileSize - bytesSent;
          if (speed > 0) {
            eta = Duration(seconds: (remaining / speed).ceil());
          }
        }
        lastProgressTime = now;

        transfer = transfer.copyWith(
          progress: progress,
          speed: speed,
          estimatedTimeLeft: eta,
        );
        _emitProgress(transfer);
      }

      // Wait for response with a timeout for large files.
      final uploadResponse = await uploadRequest.close().timeout(
        _responseTimeout,
        onTimeout: () {
          throw TimeoutException(
            'Server did not respond within ${_responseTimeout.inMinutes} minutes',
          );
        },
      );
      _activeRequest = null;

      final responseBody =
          await uploadResponse.transform(utf8.decoder).join();

      if (uploadResponse.statusCode == 200) {
        final responseJson =
            jsonDecode(responseBody) as Map<String, dynamic>;
        transfer = transfer.copyWith(
          status: TransferStatus.completed,
          progress: 1.0,
          filePath: responseJson['savePath'] as String?,
        );
      } else {
        transfer = transfer.copyWith(
          status: TransferStatus.failed,
          error:
              'Server responded with ${uploadResponse.statusCode}: $responseBody',
        );
      }
    } on TimeoutException catch (e) {
      if (_cancelRequested) {
        transfer = transfer.copyWith(status: TransferStatus.cancelled);
      } else {
        transfer = transfer.copyWith(
          status: TransferStatus.failed,
          error: 'Transfer timed out: $e',
        );
      }
    } on HttpException catch (e) {
      if (_cancelRequested) {
        transfer = transfer.copyWith(status: TransferStatus.cancelled);
      } else {
        transfer = transfer.copyWith(
          status: TransferStatus.failed,
          error: 'HTTP error: $e',
        );
      }
    } on SocketException catch (e) {
      if (_cancelRequested) {
        transfer = transfer.copyWith(status: TransferStatus.cancelled);
      } else {
        transfer = transfer.copyWith(
          status: TransferStatus.failed,
          error: 'Connection lost: $e',
        );
      }
    } catch (e) {
      if (_cancelRequested) {
        transfer = transfer.copyWith(status: TransferStatus.cancelled);
      } else {
        transfer = transfer.copyWith(
          status: TransferStatus.failed,
          error: e.toString(),
        );
      }
    }

    _emitProgress(transfer);
    return transfer;
  }

  /// Sends all files inside [folderPath] (recursively) to the [target] device.
  Future<List<Transfer>> sendFolder(Device target, String folderPath) async {
    final dir = Directory(folderPath);
    if (!dir.existsSync()) {
      throw FileSystemException('Folder not found', folderPath);
    }

    final files = dir
        .listSync(recursive: true)
        .whereType<File>()
        .toList();

    if (files.isEmpty) {
      throw FileSystemException('Folder is empty', folderPath);
    }

    final results = <Transfer>[];

    for (final file in files) {
      if (_cancelRequested) break;
      try {
        final transfer = await sendFile(target, file.path);
        results.add(transfer);
      } catch (e) {
        results.add(Transfer(
          id: '',
          fileName: file.uri.pathSegments.last,
          fileSize: 0,
          senderDevice: localDevice,
          receiverDevice: target,
          status: TransferStatus.failed,
          error: e.toString(),
          createdAt: DateTime.now(),
        ));
      }
    }

    return results;
  }

  /// Requests cancellation of the current send operation.
  void cancel() {
    _cancelRequested = true;
    try {
      _activeRequest?.abort();
    } catch (_) {}
    _activeRequest = null;
  }

  /// Releases resources held by the underlying [HttpClient].
  void dispose() {
    cancel();
    _httpClient.close(force: true);
    _progressController.close();
  }

  /// Checks if the target device is reachable by hitting /api/ping.
  ///
  /// Returns `true` if the device responds within 5 seconds.
  Future<bool> pingDevice(Device target) async {
    try {
      final pingUri = Uri.http(
        '${target.ip}:${target.port}',
        '/api/ping',
      );
      final request = await _httpClient.getUrl(pingUri);
      final response = await request.close().timeout(
        const Duration(seconds: 5),
      );
      await response.drain<void>();
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  // Helpers -------------------------------------------------------------

  /// POST with automatic retry and exponential backoff.
  Future<String> _postWithRetry(Uri uri, String body) async {
    for (int attempt = 1; attempt <= _maxRetries; attempt++) {
      try {
        return await _post(uri, body).timeout(
          const Duration(seconds: 30),
        );
      } catch (e) {
        if (attempt == _maxRetries) rethrow;
        final delay = _baseRetryDelay * (1 << (attempt - 1));
        _log.warning(
          'Request attempt $attempt failed ($e), retrying in ${delay.inSeconds}s...',
        );
        await Future<void>.delayed(delay);
      }
    }
    throw StateError('Unreachable');
  }

  /// Convenience POST that returns the response body as a [String].
  Future<String> _post(Uri uri, String body) async {
    final request = await _httpClient.postUrl(uri);
    request.headers.contentType = ContentType.json;
    request.write(body);
    final response = await request.close();
    return response.transform(utf8.decoder).join();
  }

  /// Pushes a [Transfer] snapshot to the progress stream.
  void _emitProgress(Transfer transfer) {
    if (!_progressController.isClosed) {
      _progressController.add(transfer);
    }
  }
}
