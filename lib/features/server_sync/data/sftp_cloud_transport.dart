import 'package:dartssh2/dartssh2.dart';
import 'package:anyware/core/logger.dart';
import 'package:anyware/features/server_sync/data/cloud_transport.dart';
import 'package:anyware/features/server_sync/data/sftp_transport.dart';
import 'package:anyware/features/server_sync/domain/sftp_server_config.dart';
import 'package:anyware/features/sync/data/cancellation_token.dart';
import 'package:anyware/features/sync/domain/sync_manifest.dart';

final _log = AppLogger('SftpCloudTransport');

/// Adapter that wraps the existing [SftpTransport] to implement the
/// [CloudTransport] and [RemoteBrowser] interfaces.
///
/// This avoids rewriting the battle-tested SFTP code while letting
/// [ServerSyncService] work with all providers through a single interface.
class SftpCloudTransport implements CloudTransport, RemoteBrowser {
  final SftpTransport _transport;
  final SftpServerConfig _config;

  SftpSession? _session;

  SftpCloudTransport({
    required SftpTransport transport,
    required SftpServerConfig config,
  })  : _transport = transport,
        _config = config;

  /// Active SFTP session. Throws if not connected.
  SftpClient get _sftp {
    final s = _session;
    if (s == null) {
      throw StateError('SftpCloudTransport is not connected. Call connect() first.');
    }
    return s.sftp;
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Connection lifecycle
  // ═══════════════════════════════════════════════════════════════════════════

  @override
  Future<void> connect() async {
    if (_session != null) return; // already connected
    _session = await _transport.connect(_config);
    _log.info('Connected to ${_config.host}:${_config.port}');
  }

  @override
  Future<void> disconnect() async {
    _session?.close();
    _session = null;
    _log.info('Disconnected from ${_config.host}');
  }

  @override
  Future<bool> testConnection() async {
    return _transport.testConnection(_config);
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // RemoteBrowser
  // ═══════════════════════════════════════════════════════════════════════════

  @override
  String get rootPath => _config.remotePath;

  @override
  Future<List<RemoteEntry>> listDirectory(String path) async {
    final targetPath = path.isEmpty ? _config.remotePath : path;
    final items = await _sftp.listdir(targetPath);
    final entries = <RemoteEntry>[];

    for (final item in items) {
      final name = item.filename;
      if (name == '.' || name == '..') continue;

      final fullPath = targetPath.endsWith('/')
          ? '$targetPath$name'
          : '$targetPath/$name';

      final attr = item.attr;
      entries.add(RemoteEntry(
        name: name,
        path: fullPath,
        isDirectory: attr.isDirectory,
        size: attr.isFile ? (attr.size ?? 0) : null,
        modified: attr.modifyTime != null
            ? DateTime.fromMillisecondsSinceEpoch(
                attr.modifyTime! * 1000,
                isUtc: true,
              )
            : null,
      ));
    }

    // Sort: directories first, then alphabetical.
    entries.sort((a, b) {
      if (a.isDirectory != b.isDirectory) {
        return a.isDirectory ? -1 : 1;
      }
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
    return _transport.buildRemoteManifest(_sftp, remotePath, accountId);
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
    return _transport.uploadFile(
      _sftp,
      localPath,
      remotePath,
      onProgress: onProgress,
      cancel: cancel,
    );
  }

  @override
  Future<String?> downloadFile(
    String remotePath,
    String localPath, {
    void Function(int bytesRead)? onProgress,
    CancellationToken? cancel,
  }) async {
    return _transport.downloadFile(
      _sftp,
      remotePath,
      localPath,
      onProgress: onProgress,
      cancel: cancel,
    );
  }

  @override
  Future<bool> deleteRemoteFile(String remotePath) async {
    return _transport.deleteRemoteFile(_sftp, remotePath);
  }

  @override
  Future<void> ensureRemoteDir(String path) async {
    return _transport.ensureRemoteDir(_sftp, path);
  }

  /// SFTP does not support delta queries — always returns `null`.
  @override
  Future<DeltaResult?> getDelta(String? lastToken) async => null;
}
