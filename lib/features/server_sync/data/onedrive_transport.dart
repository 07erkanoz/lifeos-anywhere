import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;

import 'package:anyware/core/logger.dart';
import 'package:anyware/features/server_sync/data/cloud_transport.dart';
import 'package:anyware/features/server_sync/data/oauth_service.dart';
import 'package:anyware/features/server_sync/data/oauth_token.dart';
import 'package:anyware/features/sync/data/cancellation_token.dart';
import 'package:anyware/features/sync/domain/sync_manifest.dart';

final _log = AppLogger('OneDriveTransport');

/// Microsoft OneDrive implementation of [CloudTransport] and [RemoteBrowser].
///
/// Uses the Microsoft Graph v1.0 REST API directly over HTTP.
class OneDriveTransport implements CloudTransport, RemoteBrowser {
  final OAuthService _oauth;
  final String _accountId;
  http.Client? _client;
  OAuthToken? _token;

  static const _graphBase = 'https://graph.microsoft.com/v1.0/me/drive';

  /// Upload session chunk size: must be a multiple of 320 KB.
  static const _chunkSize = 320 * 1024 * 10; // 3.2 MB

  /// Simple upload limit (4 MB).
  static const _simpleUploadLimit = 4 * 1024 * 1024;

  OneDriveTransport({
    required OAuthService oauth,
    required String accountId,
  })  : _oauth = oauth,
        _accountId = accountId;

  // ═══════════════════════════════════════════════════════════════════════════
  // Connection lifecycle
  // ═══════════════════════════════════════════════════════════════════════════

  @override
  Future<void> connect() async {
    if (_client != null) return;

    _token = await _oauth.getValidToken(_accountId);
    if (_token == null) {
      throw Exception('No valid Microsoft token. Please re-authenticate.');
    }

    _client = http.Client();
    _log.info('Connected to OneDrive');
  }

  @override
  Future<void> disconnect() async {
    _client?.close();
    _client = null;
    _token = null;
    _log.info('Disconnected from OneDrive');
  }

  @override
  Future<bool> testConnection() async {
    try {
      final token = await _oauth.getValidToken(_accountId);
      if (token == null) return false;

      final resp = await http.get(
        Uri.parse(_graphBase),
        headers: _authHeaders(token),
      );
      return resp.statusCode == 200;
    } catch (e) {
      _log.error('Test connection failed: $e');
      return false;
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // RemoteBrowser
  // ═══════════════════════════════════════════════════════════════════════════

  @override
  String get rootPath => '';

  @override
  Future<List<RemoteEntry>> listDirectory(String path) async {
    final token = await _ensureToken();
    final encodedPath = path.isEmpty ? 'root' : 'root:/$path:';
    final url = '$_graphBase/$encodedPath/children'
        '?\$select=name,folder,size,lastModifiedDateTime'
        '&\$top=1000';

    final entries = <RemoteEntry>[];
    String? nextLink = url;

    while (nextLink != null) {
      final resp = await _get(nextLink, token);
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      final items = data['value'] as List? ?? [];

      for (final item in items) {
        final name = item['name'] as String? ?? '';
        final isDir = item.containsKey('folder');
        final entryPath = path.isEmpty ? name : '$path/$name';

        entries.add(RemoteEntry(
          name: name,
          path: entryPath,
          isDirectory: isDir,
          size: isDir ? null : (item['size'] as int?),
          modified: item['lastModifiedDateTime'] != null
              ? DateTime.tryParse(
                  item['lastModifiedDateTime'] as String)
              : null,
        ));
      }

      nextLink = data['@odata.nextLink'] as String?;
    }

    // Sort: directories first, then alphabetical.
    entries.sort((a, b) {
      if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });

    return entries;
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Manifest
  // ═══════════════════════════════════════════════════════════════════════════

  @override
  Future<SyncManifest> buildRemoteManifest(
    String remotePath,
    String accountId,
  ) async {
    final entries = <SyncManifestEntry>[];
    await _scanRecursive(remotePath, entries);

    // Strip remotePath prefix — entries should have paths relative to remotePath.
    // _scanRecursive returns full paths (e.g. "Documents/file.doc") but the
    // diff engine expects relative paths (e.g. "file.doc") just like local manifest.
    final relativeEntries = entries.map((e) {
      var rp = e.relativePath;
      if (remotePath.isNotEmpty && rp.startsWith(remotePath)) {
        rp = rp.substring(remotePath.length);
        if (rp.startsWith('/')) rp = rp.substring(1);
      }
      return SyncManifestEntry(
        relativePath: rp,
        hash: e.hash,
        size: e.size,
        lastModified: e.lastModified,
      );
    }).toList();

    return SyncManifest(
      deviceId: accountId,
      basePath: remotePath,
      entries: relativeEntries,
      createdAt: DateTime.now(),
    );
  }

  Future<void> _scanRecursive(
    String path,
    List<SyncManifestEntry> entries,
  ) async {
    final token = await _ensureToken();
    final encodedPath = path.isEmpty ? 'root' : 'root:/$path:';
    final url = '$_graphBase/$encodedPath/children'
        '?\$select=name,folder,size,lastModifiedDateTime,file'
        '&\$top=1000';

    String? nextLink = url;

    while (nextLink != null) {
      final resp = await _get(nextLink, token);
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      final items = data['value'] as List? ?? [];

      for (final item in items) {
        final name = item['name'] as String? ?? '';
        final isDir = item.containsKey('folder');
        final entryPath = path.isEmpty ? name : '$path/$name';

        if (isDir) {
          await _scanRecursive(entryPath, entries);
        } else {
          // Extract hash from file.hashes
          String? hash;
          final fileInfo = item['file'] as Map<String, dynamic>?;
          if (fileInfo != null) {
            final hashes = fileInfo['hashes'] as Map<String, dynamic>?;
            hash = (hashes?['sha1Hash'] as String?) ??
                (hashes?['quickXorHash'] as String?);
          }

          entries.add(SyncManifestEntry(
            relativePath: entryPath,
            hash: hash,
            size: (item['size'] as int?) ?? 0,
            lastModified: item['lastModifiedDateTime'] != null
                ? DateTime.tryParse(
                        item['lastModifiedDateTime'] as String) ??
                    DateTime.now()
                : DateTime.now(),
          ));
        }
      }

      nextLink = data['@odata.nextLink'] as String?;
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // File operations
  // ═══════════════════════════════════════════════════════════════════════════

  @override
  Future<String?> uploadFile(
    String localPath,
    String remotePath, {
    void Function(int bytesWritten)? onProgress,
    CancellationToken? cancel,
  }) async {
    try {
      cancel?.throwIfCancelled();

      final file = File(localPath);
      if (!await file.exists()) return 'Local file not found: $localPath';

      final fileSize = await file.length();
      final token = await _ensureToken();

      if (fileSize < _simpleUploadLimit) {
        return _simpleUpload(file, remotePath, token, onProgress, cancel);
      } else {
        return _resumableUpload(
            file, fileSize, remotePath, token, onProgress, cancel);
      }
    } on CancelledException {
      return 'Upload cancelled';
    } catch (e) {
      _log.error('Upload failed: $e');
      return 'Upload failed: $e';
    }
  }

  Future<String?> _simpleUpload(
    File file,
    String remotePath,
    OAuthToken token,
    void Function(int)? onProgress,
    CancellationToken? cancel,
  ) async {
    cancel?.throwIfCancelled();

    final bytes = await file.readAsBytes();
    final url = '$_graphBase/root:/$remotePath:/content';

    final resp = await _client!.put(
      Uri.parse(url),
      headers: {
        ..._authHeaders(token),
        'Content-Type': 'application/octet-stream',
      },
      body: bytes,
    );

    if (resp.statusCode == 200 || resp.statusCode == 201) {
      onProgress?.call(bytes.length);
      return null; // success
    }
    return 'Upload failed (${resp.statusCode}): ${resp.body}';
  }

  Future<String?> _resumableUpload(
    File file,
    int fileSize,
    String remotePath,
    OAuthToken token,
    void Function(int)? onProgress,
    CancellationToken? cancel,
  ) async {
    // Create upload session
    final sessionUrl = '$_graphBase/root:/$remotePath:/createUploadSession';
    final sessionResp = await _client!.post(
      Uri.parse(sessionUrl),
      headers: {
        ..._authHeaders(token),
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'item': {
          '@microsoft.graph.conflictBehavior': 'replace',
        },
      }),
    );

    if (sessionResp.statusCode != 200) {
      return 'Failed to create upload session: ${sessionResp.body}';
    }

    final sessionData =
        jsonDecode(sessionResp.body) as Map<String, dynamic>;
    final uploadUrl = sessionData['uploadUrl'] as String;

    // Upload chunks
    final raf = await file.open();
    int offset = 0;

    try {
      while (offset < fileSize) {
        cancel?.throwIfCancelled();

        final end = min(offset + _chunkSize, fileSize);
        final chunkLength = end - offset;

        await raf.setPosition(offset);
        final chunk = await raf.read(chunkLength);

        final chunkResp = await _client!.put(
          Uri.parse(uploadUrl),
          headers: {
            'Content-Length': '$chunkLength',
            'Content-Range': 'bytes $offset-${end - 1}/$fileSize',
          },
          body: chunk,
        );

        if (chunkResp.statusCode != 202 &&
            chunkResp.statusCode != 200 &&
            chunkResp.statusCode != 201) {
          return 'Chunk upload failed (${chunkResp.statusCode}): ${chunkResp.body}';
        }

        offset = end;
        onProgress?.call(offset);
      }
    } finally {
      await raf.close();
    }

    return null; // success
  }

  @override
  Future<String?> downloadFile(
    String remotePath,
    String localPath, {
    void Function(int bytesRead)? onProgress,
    CancellationToken? cancel,
  }) async {
    try {
      cancel?.throwIfCancelled();

      final token = await _ensureToken();
      final url = '$_graphBase/root:/$remotePath:/content';

      final request = http.Request('GET', Uri.parse(url));
      request.headers.addAll(_authHeaders(token));

      final streamedResponse = await _client!.send(request);
      if (streamedResponse.statusCode != 200 &&
          streamedResponse.statusCode != 302) {
        return 'Download failed (${streamedResponse.statusCode})';
      }

      // If redirect, follow it
      final effectiveStream = streamedResponse.stream;

      // Write to temp file first (atomic)
      final tempPath = '$localPath.onedrive_tmp';
      final tempFile = File(tempPath);
      await tempFile.parent.create(recursive: true);

      final sink = tempFile.openWrite();
      int totalBytes = 0;

      try {
        await for (final chunk in effectiveStream) {
          cancel?.throwIfCancelled();
          sink.add(chunk);
          totalBytes += chunk.length;
          onProgress?.call(totalBytes);
        }
        await sink.flush();
      } finally {
        await sink.close();
      }

      // Atomic rename
      await tempFile.rename(localPath);
      return null; // success
    } on CancelledException {
      try {
        await File('$localPath.onedrive_tmp').delete();
      } catch (_) {}
      return 'Download cancelled';
    } catch (e) {
      _log.error('Download failed: $e');
      return 'Download failed: $e';
    }
  }

  @override
  Future<bool> deleteRemoteFile(String remotePath) async {
    try {
      final token = await _ensureToken();
      final url = '$_graphBase/root:/$remotePath';

      final resp = await _client!.delete(
        Uri.parse(url),
        headers: _authHeaders(token),
      );

      return resp.statusCode == 204 || resp.statusCode == 200;
    } catch (e) {
      _log.error('Delete failed: $e');
      return false;
    }
  }

  @override
  Future<void> ensureRemoteDir(String path) async {
    if (path.isEmpty) return;

    final token = await _ensureToken();
    final parts =
        path.split('/').where((p) => p.isNotEmpty).toList();

    String parentPath = '';
    for (final part in parts) {
      final currentPath =
          parentPath.isEmpty ? part : '$parentPath/$part';

      // Check if folder exists
      final checkUrl = '$_graphBase/root:/$currentPath';
      final resp = await _get(checkUrl, token);

      if (resp.statusCode == 404) {
        // Create it
        final parentUrl = parentPath.isEmpty
            ? '$_graphBase/root/children'
            : '$_graphBase/root:/$parentPath:/children';

        await _client!.post(
          Uri.parse(parentUrl),
          headers: {
            ..._authHeaders(token),
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            'name': part,
            'folder': {},
            '@microsoft.graph.conflictBehavior': 'fail',
          }),
        );
        _log.info('Created folder: $currentPath');
      }

      parentPath = currentPath;
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Delta sync
  // ═══════════════════════════════════════════════════════════════════════════

  @override
  Future<DeltaResult?> getDelta(String? lastToken) async {
    try {
      final token = await _ensureToken();
      final changes = <DeltaChange>[];

      // If we have a delta link, use it; otherwise start fresh
      String? nextLink = lastToken ?? '$_graphBase/root/delta';
      String? deltaLink;

      while (nextLink != null) {
        final resp = await _get(nextLink, token);
        if (resp.statusCode != 200) return null;

        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        final items = data['value'] as List? ?? [];

        for (final item in items) {
          final name = item['name'] as String? ?? '';
          final isDir = item.containsKey('folder');
          final deleted = item.containsKey('deleted') ||
              (item['deleted'] != null);

          if (isDir) continue; // skip folder entries

          if (deleted) {
            changes.add(DeltaChange(
              relativePath: name,
              type: DeltaChangeType.deleted,
            ));
          } else {
            final hashes =
                (item['file'] as Map<String, dynamic>?)?['hashes']
                    as Map<String, dynamic>?;
            changes.add(DeltaChange(
              relativePath: name,
              type: DeltaChangeType.modified,
              size: item['size'] as int?,
              modified: item['lastModifiedDateTime'] != null
                  ? DateTime.tryParse(
                      item['lastModifiedDateTime'] as String)
                  : null,
              hash: hashes?['sha1Hash'] as String?,
            ));
          }
        }

        deltaLink = data['@odata.deltaLink'] as String?;
        nextLink = data['@odata.nextLink'] as String?;
      }

      return DeltaResult(
        changes: changes,
        newToken: deltaLink ?? lastToken ?? '',
      );
    } catch (e) {
      _log.error('Delta query failed: $e');
      return null;
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Helpers
  // ═══════════════════════════════════════════════════════════════════════════

  Map<String, String> _authHeaders(OAuthToken token) => {
        'Authorization': 'Bearer ${token.accessToken}',
      };

  /// Ensure we have a valid (non-expired) token, refreshing if needed.
  Future<OAuthToken> _ensureToken() async {
    if (_token != null && !_token!.isExpired) return _token!;

    _token = await _oauth.getValidToken(_accountId);
    if (_token == null) {
      throw Exception('No valid Microsoft token. Please re-authenticate.');
    }
    return _token!;
  }

  /// GET request with auth headers and automatic 401 retry.
  Future<http.Response> _get(String url, OAuthToken token) async {
    var resp = await _client!.get(
      Uri.parse(url),
      headers: _authHeaders(token),
    );

    if (resp.statusCode == 401) {
      _token = await _oauth.getValidToken(_accountId);
      if (_token != null) {
        resp = await _client!.get(
          Uri.parse(url),
          headers: _authHeaders(_token!),
        );
      }
    }

    return resp;
  }
}
