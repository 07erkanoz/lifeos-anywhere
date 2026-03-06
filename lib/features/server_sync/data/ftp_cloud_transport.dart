import 'dart:io';

import 'package:ftpconnect/ftpconnect.dart';

import 'package:anyware/core/logger.dart';
import 'package:anyware/features/server_sync/data/cloud_transport.dart';
import 'package:anyware/features/sync/data/cancellation_token.dart';
import 'package:anyware/features/sync/domain/sync_manifest.dart';

final _log = AppLogger('FtpTransport');

/// CloudTransport + RemoteBrowser implementation for plain FTP servers.
class FtpCloudTransport implements CloudTransport, RemoteBrowser {
  final String _host;
  final int _port;
  final String _username;
  final String _password;
  final String _basePath;

  FTPConnect? _ftp;

  FtpCloudTransport({
    required String host,
    required int port,
    required String username,
    required String password,
    String basePath = '/',
  })  : _host = host,
        _port = port,
        _username = username,
        _password = password,
        _basePath = basePath;

  // ═══════════════════════════════════════════════════════════════════════════
  // Connection lifecycle
  // ═══════════════════════════════════════════════════════════════════════════

  @override
  Future<void> connect() async {
    if (_ftp != null) return;
    _ftp = FTPConnect(
      _host,
      port: _port,
      user: _username,
      pass: _password,
      timeout: 15,
    );
    final ok = await _ftp!.connect();
    if (!ok) {
      _ftp = null;
      throw Exception('FTP connection failed to $_host:$_port');
    }
    _log.info('Connected to $_host:$_port');
  }

  @override
  Future<void> disconnect() async {
    try {
      await _ftp?.disconnect();
    } catch (_) {}
    _ftp = null;
    _log.info('Disconnected from $_host');
  }

  @override
  Future<bool> testConnection() async {
    FTPConnect? testFtp;
    try {
      testFtp = FTPConnect(
        _host,
        port: _port,
        user: _username,
        pass: _password,
        timeout: 10,
      );
      final ok = await testFtp.connect();
      if (!ok) return false;
      // Try to list root to verify access.
      await testFtp.listDirectoryContent();
      return true;
    } catch (e) {
      _log.warning('Test connection failed: $e');
      return false;
    } finally {
      try {
        await testFtp?.disconnect();
      } catch (_) {}
    }
  }

  FTPConnect get _c {
    final c = _ftp;
    if (c == null) {
      throw StateError('FtpCloudTransport not connected. Call connect() first.');
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
    await _c.changeDirectory(targetPath);
    final items = await _c.listDirectoryContent();

    final entries = <RemoteEntry>[];
    for (final item in items) {
      final name = item.name;
      if (name == '.' || name == '..') continue;

      final fullPath = targetPath.endsWith('/')
          ? '$targetPath$name'
          : '$targetPath/$name';

      entries.add(RemoteEntry(
        name: name,
        path: fullPath,
        isDirectory: item.type == FTPEntryType.DIR,
        size: item.type == FTPEntryType.FILE ? (item.size ?? 0) : null,
        modified: item.modifyTime,
      ));
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
    await _scanDir(remotePath, remotePath, entries);

    return SyncManifest(
      deviceId: 'ftp-$accountId',
      basePath: remotePath,
      createdAt: DateTime.now().toUtc(),
      entries: entries,
    );
  }

  Future<void> _scanDir(
    String basePath,
    String currentPath,
    List<SyncManifestEntry> entries,
  ) async {
    final items = await listDirectory(currentPath);

    for (final item in items) {
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

      final file = File(localPath);
      if (!await file.exists()) return 'Local file not found: $localPath';

      // Ensure remote directory exists.
      final remoteDir = remotePath.substring(0, remotePath.lastIndexOf('/'));
      if (remoteDir.isNotEmpty) {
        await ensureRemoteDir(remoteDir);
      }

      // Navigate to the remote directory.
      await _c.changeDirectory(remoteDir.isEmpty ? '/' : remoteDir);

      final ok = await _c.uploadFile(file);
      if (!ok) return 'FTP upload failed for $remotePath';

      // Report final size as progress.
      if (onProgress != null) {
        final size = await file.length();
        onProgress(size);
      }

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

      // Navigate to the remote directory.
      final remoteDir = remotePath.substring(0, remotePath.lastIndexOf('/'));
      await _c.changeDirectory(remoteDir.isEmpty ? '/' : remoteDir);

      final outFile = File(localPath);
      final ok = await _c.downloadFile(remotePath, outFile);
      if (!ok) return 'FTP download failed for $remotePath';

      // Report file size as progress.
      if (onProgress != null) {
        final size = await outFile.length();
        onProgress(size);
      }

      return null; // success
    } catch (e) {
      _log.warning('Download failed ($remotePath): $e');
      return e.toString();
    }
  }

  @override
  Future<bool> deleteRemoteFile(String remotePath) async {
    try {
      final ok = await _c.deleteFile(remotePath);
      return ok;
    } catch (e) {
      _log.warning('Delete failed ($remotePath): $e');
      return false;
    }
  }

  @override
  Future<void> ensureRemoteDir(String path) async {
    try {
      await _c.makeDirectory(path);
    } catch (e) {
      // Directory may already exist — FTP MKD returns error in that case.
      // We ignore the error and verify by trying to CWD into it.
      try {
        await _c.changeDirectory(path);
      } catch (_) {
        _log.warning('ensureRemoteDir failed ($path): $e');
        rethrow;
      }
    }
  }

  /// FTP does not support delta queries — always returns `null`.
  @override
  Future<DeltaResult?> getDelta(String? lastToken) async => null;
}
