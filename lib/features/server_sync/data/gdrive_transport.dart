import 'dart:async';
import 'dart:io';

import 'package:googleapis/drive/v3.dart' as drive;
import 'package:http/http.dart' as http;

import 'package:anyware/core/logger.dart';
import 'package:anyware/features/server_sync/data/cloud_transport.dart';
import 'package:anyware/features/server_sync/data/oauth_service.dart';
import 'package:anyware/features/server_sync/data/oauth_token.dart';
import 'package:anyware/features/sync/data/cancellation_token.dart';
import 'package:anyware/features/sync/domain/sync_manifest.dart';

final _log = AppLogger('GDriveTransport');

/// Google Drive implementation of [CloudTransport] and [RemoteBrowser].
///
/// Uses the googleapis Dart package for Drive v3 operations.
/// Automatically refreshes tokens via [OAuthService].
class GDriveTransport implements CloudTransport, RemoteBrowser {
  final OAuthService _oauth;
  final String _accountId;

  /// The authenticated HTTP client with auto-refresh.
  _AutoRefreshClient? _client;

  /// Google Drive API handle.
  drive.DriveApi? _driveApi;

  /// Cache: virtual path → Google Drive folder ID.
  final Map<String, String> _folderIdCache = {};

  /// Start page token for delta queries.
  String? _startPageToken;

  GDriveTransport({
    required OAuthService oauth,
    required String accountId,
  })  : _oauth = oauth,
        _accountId = accountId;

  drive.DriveApi get _api {
    if (_driveApi == null) {
      throw StateError('Not connected. Call connect() first.');
    }
    return _driveApi!;
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Connection lifecycle
  // ═══════════════════════════════════════════════════════════════════════════

  @override
  Future<void> connect() async {
    if (_driveApi != null) return;

    final token = await _oauth.getValidToken(_accountId);
    if (token == null) {
      throw Exception('No valid Google token. Please re-authenticate.');
    }

    _client = _AutoRefreshClient(token, _oauth, _accountId);
    _driveApi = drive.DriveApi(_client!);

    // Cache the start page token for delta queries.
    try {
      final start = await _api.changes.getStartPageToken();
      _startPageToken = start.startPageToken;
    } catch (_) {}

    _log.info('Connected to Google Drive');
  }

  @override
  Future<void> disconnect() async {
    _client?.close();
    _client = null;
    _driveApi = null;
    _folderIdCache.clear();
    _log.info('Disconnected from Google Drive');
  }

  @override
  Future<bool> testConnection() async {
    try {
      final token = await _oauth.getValidToken(_accountId);
      if (token == null) return false;

      final client = _AutoRefreshClient(token, _oauth, _accountId);
      try {
        final api = drive.DriveApi(client);
        await api.about.get($fields: 'user');
        return true;
      } finally {
        client.close();
      }
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
    final folderId = await _resolveFolderId(path);

    final entries = <RemoteEntry>[];
    String? pageToken;

    do {
      final result = await _api.files.list(
        q: "'$folderId' in parents and trashed = false",
        $fields:
            'nextPageToken, files(id, name, mimeType, size, modifiedTime)',
        pageSize: 1000,
        pageToken: pageToken,
        orderBy: 'folder, name',
      );

      for (final file in result.files ?? <drive.File>[]) {
        final isDir =
            file.mimeType == 'application/vnd.google-apps.folder';
        entries.add(RemoteEntry(
          name: file.name ?? '',
          path: path.isEmpty
              ? file.name ?? ''
              : '$path/${file.name ?? ''}',
          isDirectory: isDir,
          size: isDir ? null : int.tryParse(file.size ?? ''),
          modified: file.modifiedTime,
        ));
      }

      pageToken = result.nextPageToken;
    } while (pageToken != null);

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

    return SyncManifest(
      deviceId: accountId,
      basePath: remotePath,
      entries: entries,
      createdAt: DateTime.now(),
    );
  }

  Future<void> _scanRecursive(
    String path,
    List<SyncManifestEntry> entries,
  ) async {
    final items = await listDirectory(path);
    for (final item in items) {
      if (item.isDirectory) {
        await _scanRecursive(item.path, entries);
      } else {
        // Resolve Google Drive file ID to get md5 checksum.
        final fileId = await _resolveFileId(item.path);
        String? hash;
        if (fileId != null) {
          try {
            final meta = await _api.files.get(
              fileId,
              $fields: 'md5Checksum',
            ) as drive.File;
            hash = meta.md5Checksum;
          } catch (_) {}
        }

        entries.add(SyncManifestEntry(
          relativePath: item.path,
          hash: hash,
          size: item.size ?? 0,
          lastModified: item.modified ?? DateTime.now(),
        ));
      }
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
      final parentPath = _parentOf(remotePath);
      final fileName = _nameOf(remotePath);

      // Ensure parent folder exists
      await ensureRemoteDir(parentPath);
      final parentId = await _resolveFolderId(parentPath);

      // Check if file already exists (update vs create)
      final existingId = await _resolveFileId(remotePath);

      final media = drive.Media(
        _progressStream(file.openRead(), onProgress, cancel),
        fileSize,
      );

      if (existingId != null) {
        // Update existing file
        await _api.files.update(
          drive.File(),
          existingId,
          uploadMedia: media,
        );
      } else {
        // Create new file
        final driveFile = drive.File()
          ..name = fileName
          ..parents = [parentId];
        await _api.files.create(
          driveFile,
          uploadMedia: media,
        );
      }

      return null; // success
    } on CancelledException {
      return 'Upload cancelled';
    } catch (e) {
      _log.error('Upload failed: $e');
      return 'Upload failed: $e';
    }
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

      final fileId = await _resolveFileId(remotePath);
      if (fileId == null) return 'Remote file not found: $remotePath';

      final media = await _api.files.get(
        fileId,
        downloadOptions: drive.DownloadOptions.fullMedia,
      ) as drive.Media;

      // Write to temp file first, then rename (atomic)
      final tempPath = '$localPath.gdrive_tmp';
      final tempFile = File(tempPath);
      await tempFile.parent.create(recursive: true);

      final sink = tempFile.openWrite();
      int totalBytes = 0;

      try {
        await for (final chunk in media.stream) {
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
      // Cleanup temp file
      try {
        await File('$localPath.gdrive_tmp').delete();
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
      final fileId = await _resolveFileId(remotePath);
      if (fileId == null) return false;
      await _api.files.delete(fileId);
      return true;
    } catch (e) {
      _log.error('Delete failed: $e');
      return false;
    }
  }

  @override
  Future<void> ensureRemoteDir(String path) async {
    if (path.isEmpty) return;
    // _resolveFolderId already creates missing folders.
    await _resolveFolderId(path);
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Delta sync
  // ═══════════════════════════════════════════════════════════════════════════

  @override
  Future<DeltaResult?> getDelta(String? lastToken) async {
    try {
      final token = lastToken ?? _startPageToken;
      if (token == null) return null;

      final changes = <DeltaChange>[];
      String? pageToken = token;
      String? newStartPageToken;

      while (pageToken != null) {
        final result = await _api.changes.list(
          pageToken,
          $fields:
              'nextPageToken, newStartPageToken, changes(fileId, removed, file(name, mimeType, size, modifiedTime, parents, trashed))',
          spaces: 'drive',
          includeRemoved: true,
        );

        for (final change in result.changes ?? <drive.Change>[]) {
          if (change.removed == true ||
              (change.file?.trashed ?? false)) {
            changes.add(DeltaChange(
              relativePath: change.file?.name ?? change.fileId ?? '',
              type: DeltaChangeType.deleted,
            ));
          } else if (change.file != null) {
            final f = change.file!;
            final isDir =
                f.mimeType == 'application/vnd.google-apps.folder';
            if (!isDir) {
              changes.add(DeltaChange(
                relativePath: f.name ?? '',
                type: DeltaChangeType.modified,
                size: int.tryParse(f.size ?? ''),
                modified: f.modifiedTime,
              ));
            }
          }
        }

        newStartPageToken = result.newStartPageToken;
        pageToken = result.nextPageToken;
      }

      return DeltaResult(
        changes: changes,
        newToken: newStartPageToken ?? token,
      );
    } catch (e) {
      _log.error('Delta query failed: $e');
      return null;
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Path → ID resolution (with caching & auto-creation)
  // ═══════════════════════════════════════════════════════════════════════════

  /// Resolve a virtual path like "Documents/Projects" to a Google Drive folder ID.
  /// Creates missing folders along the way.
  Future<String> _resolveFolderId(String path) async {
    if (path.isEmpty) return 'root';

    // Check cache
    if (_folderIdCache.containsKey(path)) return _folderIdCache[path]!;

    final parts =
        path.split('/').where((p) => p.isNotEmpty).toList();

    String parentId = 'root';
    String builtPath = '';

    for (final part in parts) {
      builtPath = builtPath.isEmpty ? part : '$builtPath/$part';

      // Check cache for this partial path
      if (_folderIdCache.containsKey(builtPath)) {
        parentId = _folderIdCache[builtPath]!;
        continue;
      }

      // Search for existing folder
      final result = await _api.files.list(
        q: "name = '$part' and '$parentId' in parents and mimeType = 'application/vnd.google-apps.folder' and trashed = false",
        $fields: 'files(id)',
        pageSize: 1,
      );

      if (result.files != null && result.files!.isNotEmpty) {
        parentId = result.files!.first.id!;
      } else {
        // Create folder
        final folder = drive.File()
          ..name = part
          ..mimeType = 'application/vnd.google-apps.folder'
          ..parents = [parentId];
        final created = await _api.files.create(folder);
        parentId = created.id!;
        _log.info('Created folder: $builtPath (id=$parentId)');
      }

      _folderIdCache[builtPath] = parentId;
    }

    return parentId;
  }

  /// Resolve a virtual file path to its Google Drive file ID.
  /// Returns `null` if the file doesn't exist.
  Future<String?> _resolveFileId(String path) async {
    if (path.isEmpty) return null;

    final parentPath = _parentOf(path);
    final fileName = _nameOf(path);

    try {
      final parentId = await _resolveFolderId(parentPath);
      final result = await _api.files.list(
        q: "name = '$fileName' and '$parentId' in parents and trashed = false",
        $fields: 'files(id)',
        pageSize: 1,
      );

      return result.files?.isNotEmpty == true
          ? result.files!.first.id
          : null;
    } catch (_) {
      return null;
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Helpers
  // ═══════════════════════════════════════════════════════════════════════════

  String _parentOf(String path) {
    final lastSlash = path.lastIndexOf('/');
    return lastSlash <= 0 ? '' : path.substring(0, lastSlash);
  }

  String _nameOf(String path) {
    final lastSlash = path.lastIndexOf('/');
    return lastSlash < 0 ? path : path.substring(lastSlash + 1);
  }

  /// Wraps a byte stream with progress reporting and cancellation checks.
  Stream<List<int>> _progressStream(
    Stream<List<int>> source,
    void Function(int)? onProgress,
    CancellationToken? cancel,
  ) async* {
    int total = 0;
    await for (final chunk in source) {
      cancel?.throwIfCancelled();
      yield chunk;
      total += chunk.length;
      onProgress?.call(total);
    }
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// Auto-refreshing HTTP client wrapper
// ═══════════════════════════════════════════════════════════════════════════════

/// An [http.BaseClient] that injects the Bearer token and refreshes it
/// automatically when a 401 response is received.
class _AutoRefreshClient extends http.BaseClient {
  OAuthToken _token;
  final OAuthService _oauth;
  final String _accountId;
  final http.Client _inner = http.Client();

  _AutoRefreshClient(this._token, this._oauth, this._accountId);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    // Proactively refresh if expired
    if (_token.isExpired && _token.canRefresh) {
      _token = await _oauth.refreshToken(_accountId, _token);
    }

    request.headers['Authorization'] = 'Bearer ${_token.accessToken}';
    var response = await _inner.send(request);

    // Retry once on 401
    if (response.statusCode == 401 && _token.canRefresh) {
      _token = await _oauth.refreshToken(_accountId, _token);
      // Clone the request (BaseRequest can't be reused directly)
      final retryRequest = _copyRequest(request);
      retryRequest.headers['Authorization'] =
          'Bearer ${_token.accessToken}';
      response = await _inner.send(retryRequest);
    }

    return response;
  }

  http.Request _copyRequest(http.BaseRequest original) {
    final copy = http.Request(original.method, original.url);
    copy.headers.addAll(original.headers);
    if (original is http.Request) {
      copy.body = original.body;
    }
    return copy;
  }

  @override
  void close() {
    _inner.close();
  }
}
