import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:anyware/core/logger.dart';
import 'package:anyware/features/server_sync/domain/sftp_server_config.dart';
import 'package:anyware/features/sync/domain/sync_manifest.dart';

final _log = AppLogger('SftpTransport');

/// Encapsulates all SFTP operations: connect, list, upload, download, delete.
///
/// Stateless — call [connect] to obtain a session, then pass it to other
/// methods. The caller is responsible for closing the session.
class SftpTransport {
  // ═══════════════════════════════════════════════════════════════════════════
  // Connection
  // ═══════════════════════════════════════════════════════════════════════════

  /// Open an SSH + SFTP session to [server].
  Future<SftpSession> connect(SftpServerConfig server) async {
    _log.info('Connecting to ${server.host}:${server.port}');
    final socket = await SSHSocket.connect(server.host, server.port,
        timeout: const Duration(seconds: 15));

    final client = SSHClient(
      socket,
      username: server.username,
      onPasswordRequest: server.authMethod == 'password'
          ? () => server.password
          : null,
      identities: server.authMethod == 'key' && server.privateKey != null
          ? _parseIdentities(server.privateKey!, server.passphrase)
          : null,
    );

    final sftp = await client.sftp();
    _log.info('SFTP session established to ${server.host}');
    return SftpSession(client: client, sftp: sftp);
  }

  /// Quick connectivity test — connect, stat remotePath, disconnect.
  Future<bool> testConnection(SftpServerConfig server) async {
    SftpSession? session;
    try {
      session = await connect(server);
      await session.sftp.stat(server.remotePath);
      _log.info('Connection test OK for ${server.host}');
      return true;
    } catch (e) {
      _log.error('Connection test failed for ${server.host}: $e', error: e);
      return false;
    } finally {
      session?.close();
    }
  }

  List<SSHKeyPair> _parseIdentities(String privateKey, String? passphrase) {
    try {
      if (passphrase != null && passphrase.isNotEmpty) {
        return SSHKeyPair.fromPem(privateKey, passphrase);
      }
      return SSHKeyPair.fromPem(privateKey);
    } catch (e) {
      _log.error('Failed to parse private key: $e', error: e);
      return [];
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Remote manifest (directory listing)
  // ═══════════════════════════════════════════════════════════════════════════

  /// Recursively list files under [remotePath] and build a [SyncManifest].
  Future<SyncManifest> buildRemoteManifest(
    SftpClient sftp,
    String remotePath,
    String serverId,
  ) async {
    _log.info('Building remote manifest for $remotePath');
    final entries = <SyncManifestEntry>[];
    await _listRecursive(sftp, remotePath, remotePath, entries);
    _log.info('Remote manifest: ${entries.length} files');
    return SyncManifest(
      deviceId: 'sftp:$serverId',
      basePath: remotePath,
      createdAt: DateTime.now().toUtc(),
      entries: entries,
    );
  }

  Future<void> _listRecursive(
    SftpClient sftp,
    String basePath,
    String currentPath,
    List<SyncManifestEntry> entries,
  ) async {
    final items = await sftp.listdir(currentPath);
    for (final item in items) {
      final name = item.filename;
      if (name == '.' || name == '..') continue;

      final fullPath = currentPath.endsWith('/')
          ? '$currentPath$name'
          : '$currentPath/$name';

      final attr = item.attr;
      if (attr.isDirectory) {
        await _listRecursive(sftp, basePath, fullPath, entries);
      } else if (attr.isFile) {
        // Build relative path with / separators.
        var relativePath = fullPath;
        if (relativePath.startsWith(basePath)) {
          relativePath = relativePath.substring(basePath.length);
          if (relativePath.startsWith('/')) {
            relativePath = relativePath.substring(1);
          }
        }
        entries.add(SyncManifestEntry(
          relativePath: relativePath,
          size: attr.size ?? 0,
          lastModified: attr.modifyTime != null
              ? DateTime.fromMillisecondsSinceEpoch(
                  attr.modifyTime! * 1000,
                  isUtc: true)
              : DateTime.now().toUtc(),
        ));
      }
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // File operations
  // ═══════════════════════════════════════════════════════════════════════════

  /// Upload a local file to [remotePath].
  ///
  /// Returns `null` on success, or an error message on failure.
  Future<String?> uploadFile(
    SftpClient sftp,
    String localPath,
    String remotePath, {
    void Function(int bytesWritten)? onProgress,
  }) async {
    try {
      // Ensure parent directories exist.
      final parentDir = remotePath.substring(0, remotePath.lastIndexOf('/'));
      await ensureRemoteDir(sftp, parentDir);

      final localFile = File(localPath);
      final fileSize = await localFile.length();
      final remoteFile = await sftp.open(
        remotePath,
        mode: SftpFileOpenMode.create |
            SftpFileOpenMode.write |
            SftpFileOpenMode.truncate,
      );

      try {
        final stream = localFile.openRead();
        int written = 0;
        await for (final chunk in stream) {
          await remoteFile.write(Stream.value(Uint8List.fromList(chunk)),
              offset: written);
          written += chunk.length;
          onProgress?.call(written);
        }
        _log.info('Uploaded $localPath → $remotePath ($fileSize bytes)');
      } finally {
        await remoteFile.close();
      }

      // Try to set the modification time to match the local file.
      try {
        final localStat = await localFile.stat();
        await sftp.setStat(remotePath, SftpFileAttrs(
          modifyTime: localStat.modified.millisecondsSinceEpoch ~/ 1000,
        ));
      } catch (_) {
        // Not critical — some servers don't support setstat.
      }

      return null;
    } catch (e) {
      _log.error('Upload failed: $localPath → $remotePath: $e', error: e);
      return e.toString();
    }
  }

  /// Download a remote file to [localPath].
  ///
  /// Returns `null` on success, or an error message on failure.
  Future<String?> downloadFile(
    SftpClient sftp,
    String remotePath,
    String localPath, {
    void Function(int bytesRead)? onProgress,
  }) async {
    try {
      final localFile = File(localPath);
      await localFile.parent.create(recursive: true);

      final remoteFile = await sftp.open(remotePath);
      try {
        final remoteStat = await remoteFile.stat();
        final sink = localFile.openWrite();
        int read = 0;

        await for (final chunk in remoteFile.read()) {
          sink.add(chunk);
          read += chunk.length;
          onProgress?.call(read);
        }
        await sink.flush();
        await sink.close();

        // Restore modification time from remote.
        if (remoteStat.modifyTime != null) {
          try {
            await localFile.setLastModified(DateTime.fromMillisecondsSinceEpoch(
              remoteStat.modifyTime! * 1000,
            ));
          } catch (_) {}
        }

        _log.info('Downloaded $remotePath → $localPath');
      } finally {
        await remoteFile.close();
      }
      return null;
    } catch (e) {
      _log.error('Download failed: $remotePath → $localPath: $e', error: e);
      return e.toString();
    }
  }

  /// Delete a file on the remote server.
  Future<bool> deleteRemoteFile(SftpClient sftp, String remotePath) async {
    try {
      await sftp.remove(remotePath);
      _log.info('Deleted remote file: $remotePath');
      return true;
    } catch (e) {
      _log.error('Failed to delete $remotePath: $e', error: e);
      return false;
    }
  }

  /// Recursively ensure remote directories exist.
  Future<void> ensureRemoteDir(SftpClient sftp, String path) async {
    try {
      await sftp.stat(path);
      return; // Already exists.
    } catch (_) {
      // Doesn't exist — create recursively.
    }

    final parts = path.split('/').where((s) => s.isNotEmpty).toList();
    var current = '';
    for (final part in parts) {
      current = '$current/$part';
      try {
        await sftp.stat(current);
      } catch (_) {
        try {
          await sftp.mkdir(current);
        } catch (_) {
          // May already exist from a race condition — ignore.
        }
      }
    }
  }
}

/// Holds an active SSH client + SFTP sub-system together for easy cleanup.
class SftpSession {
  final SSHClient client;
  final SftpClient sftp;

  SftpSession({required this.client, required this.sftp});

  void close() {
    try {
      client.close();
    } catch (_) {}
  }
}
