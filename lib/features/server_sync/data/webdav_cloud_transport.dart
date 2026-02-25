import 'dart:io';

import 'package:webdav_client/webdav_client.dart' as webdav;

import 'package:anyware/core/logger.dart';
import 'package:anyware/features/server_sync/data/cloud_transport.dart';
import 'package:anyware/features/sync/data/cancellation_token.dart';
import 'package:anyware/features/sync/domain/sync_manifest.dart';

final _log = AppLogger('WebDavTransport');

/// CloudTransport + RemoteBrowser implementation for WebDAV servers
/// (Nextcloud, ownCloud, Synology NAS, pCloud, Box, etc.).
class WebDavCloudTransport implements CloudTransport, RemoteBrowser {
  final String _url;
  final String _username;
  final String _password;
  final String _basePath;

  webdav.Client? _client;

  WebDavCloudTransport({
    required String url,
    required String username,
    required String password,
    String basePath = '/',
  })  : _url = url,
        _username = username,
        _password = password,
        _basePath = basePath;

  // ═══════════════════════════════════════════════════════════════════════════
  // Connection lifecycle
  // ═══════════════════════════════════════════════════════════════════════════

  @override
  Future<void> connect() async {
    if (_client != null) return;
    _client = webdav.newClient(_url, user: _username, password: _password);
    // Generous timeout for large files / slow networks.
    _client!.setConnectTimeout(15000);
    _client!.setSendTimeout(0); // unlimited for uploads
    _client!.setReceiveTimeout(0); // unlimited for downloads
    _log.info('Connected to $_url');
  }

  @override
  Future<void> disconnect() async {
    _client = null;
    _log.info('Disconnected from $_url');
  }

  @override
  Future<bool> testConnection() async {
    try {
      final c = webdav.newClient(_url, user: _username, password: _password);
      c.setConnectTimeout(10000);
      await c.ping();
      return true;
    } catch (e) {
      _log.warning('Test connection failed: $e');
      return false;
    }
  }

  webdav.Client get _c {
    final c = _client;
    if (c == null) {
      throw StateError('WebDavCloudTransport not connected. Call connect() first.');
    }
    return c;
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // RemoteBrowser
  // ═══════════════════════════════════════════════════════════════════════════

  @override
  String get rootPath => _basePath;

  @override
  Future<List<RemoteEntry>> listDirectory(String path) async {
    final targetPath = path.isEmpty ? _basePath : path;
    final items = await _c.readDir(targetPath);

    final entries = items
        .where((f) => f.name != null && f.name != '.' && f.name != '..')
        .map((f) {
      final name = f.name!;
      final filePath = f.path ?? '$targetPath/$name';
      return RemoteEntry(
        name: name,
        path: filePath,
        isDirectory: f.isDir ?? false,
        size: (f.isDir ?? false) ? null : f.size,
        modified: f.mTime,
      );
    }).toList();

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
    await _scanDir(remotePath, remotePath, entries);

    return SyncManifest(
      deviceId: 'webdav-$accountId',
      basePath: remotePath,
      createdAt: DateTime.now().toUtc(),
      entries: entries,
    );
  }

  /// Recursive directory scanner for building manifests.
  Future<void> _scanDir(
    String basePath,
    String currentPath,
    List<SyncManifestEntry> entries,
  ) async {
    final items = await listDirectory(currentPath);

    for (final item in items) {
      // Compute relative path from base.
      var relPath = item.path;
      if (relPath.startsWith(basePath)) {
        relPath = relPath.substring(basePath.length);
      }
      if (relPath.startsWith('/')) relPath = relPath.substring(1);
      if (relPath.isEmpty) continue;

      if (item.isDirectory) {
        await _scanDir(basePath, item.path, entries);
      } else {
        entries.add(SyncManifestEntry(
          relativePath: relPath,
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
      if (cancel != null && cancel.isCancelled) return 'Cancelled';

      await _c.writeFromFile(
        localPath,
        remotePath,
        onProgress: onProgress != null
            ? (count, total) {
                onProgress(count);
                // Check cancellation on each progress tick.
                if (cancel != null && cancel.isCancelled) {
                  throw CancelledException();
                }
              }
            : null,
      );

      return null; // success
    } on CancelledException {
      return 'Cancelled';
    } catch (e) {
      _log.warning('Upload failed ($remotePath): $e');
      return e.toString();
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
      // Ensure parent directory exists.
      final dir = Directory(localPath).parent;
      if (!await dir.exists()) await dir.create(recursive: true);

      await _c.read2File(
        remotePath,
        localPath,
        onProgress: onProgress != null
            ? (count, total) => onProgress(count)
            : null,
      );

      return null; // success
    } catch (e) {
      _log.warning('Download failed ($remotePath): $e');
      return e.toString();
    }
  }

  @override
  Future<bool> deleteRemoteFile(String remotePath) async {
    try {
      await _c.remove(remotePath);
      return true;
    } catch (e) {
      _log.warning('Delete failed ($remotePath): $e');
      return false;
    }
  }

  @override
  Future<void> ensureRemoteDir(String path) async {
    try {
      await _c.mkdirAll(path);
    } catch (e) {
      _log.warning('mkdir failed ($path): $e');
      rethrow;
    }
  }

  /// WebDAV does not support delta queries — always returns `null`.
  @override
  Future<DeltaResult?> getDelta(String? lastToken) async => null;
}
