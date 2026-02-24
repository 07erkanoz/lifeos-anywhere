import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:anyware/core/logger.dart';
import 'package:anyware/features/server_sync/domain/sftp_server_config.dart';
import 'package:anyware/features/sync/data/cancellation_token.dart';
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
  /// Supports byte-level resume: if a `.sync_tmp` temp file exists on the
  /// server from a previous attempt, the upload resumes from where it left off.
  ///
  /// Returns `null` on success, or an error message on failure.
  Future<String?> uploadFile(
    SftpClient sftp,
    String localPath,
    String remotePath, {
    void Function(int bytesWritten)? onProgress,
    CancellationToken? cancel,
  }) async {
    try {
      // Ensure parent directories exist.
      final parentDir = remotePath.substring(0, remotePath.lastIndexOf('/'));
      await ensureRemoteDir(sftp, parentDir);

      final localFile = File(localPath);
      final fileSize = await localFile.length();

      // Upload to temp path, then SFTP rename for atomicity.
      final tempRemotePath = '$remotePath.sync_tmp';

      // ── Byte-level resume: check for partial upload on server ──
      int resumeOffset = 0;
      try {
        final remoteStat = await sftp.stat(tempRemotePath);
        final remoteSize = remoteStat.size ?? 0;
        if (remoteSize > 0 && remoteSize < fileSize) {
          resumeOffset = remoteSize;
          _log.info(
            'Found partial SFTP upload for $remotePath: '
            '$resumeOffset / $fileSize bytes',
          );
        }
      } catch (_) {
        // Temp file doesn't exist — fresh upload.
      }

      final SftpFile remoteFile;
      if (resumeOffset > 0) {
        // Append to existing temp file.
        remoteFile = await sftp.open(
          tempRemotePath,
          mode: SftpFileOpenMode.create |
              SftpFileOpenMode.write |
              SftpFileOpenMode.append,
        );
      } else {
        // Fresh upload — truncate if exists.
        remoteFile = await sftp.open(
          tempRemotePath,
          mode: SftpFileOpenMode.create |
              SftpFileOpenMode.write |
              SftpFileOpenMode.truncate,
        );
      }

      try {
        final stream = localFile.openRead(resumeOffset > 0 ? resumeOffset : 0);
        int written = resumeOffset;
        bool cancelled = false;
        await for (final chunk in stream) {
          if (cancel != null && cancel.isCancelled) {
            cancelled = true;
            break;
          }
          await remoteFile.write(Stream.value(Uint8List.fromList(chunk)),
              offset: written);
          written += chunk.length;
          onProgress?.call(written);
        }
        if (cancelled) {
          _log.info('Upload cancelled: $localPath (at $written bytes)');
          await remoteFile.close();
          // Leave temp file for resume on next attempt.
          return 'Cancelled';
        }
        _log.info('Uploaded $localPath → $tempRemotePath ($fileSize bytes'
            '${resumeOffset > 0 ? ', resumed from $resumeOffset' : ''})');
      } finally {
        await remoteFile.close();
      }

      // Atomic rename on the SFTP server.
      try {
        // Remove existing target first (some SFTP servers don't allow rename-over).
        try {
          await sftp.remove(remotePath);
        } catch (_) {}
        await sftp.rename(tempRemotePath, remotePath);
      } catch (e) {
        _log.warning(
            'SFTP rename failed ($tempRemotePath → $remotePath): $e');
        // Clean up temp file on rename failure.
        try {
          await sftp.remove(tempRemotePath);
        } catch (_) {}
        rethrow;
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
  /// Supports byte-level resume: if a `.sync_tmp` temp file exists locally,
  /// the download resumes from where it left off.
  ///
  /// Returns `null` on success, or an error message on failure.
  Future<String?> downloadFile(
    SftpClient sftp,
    String remotePath,
    String localPath, {
    void Function(int bytesRead)? onProgress,
    CancellationToken? cancel,
  }) async {
    try {
      // Download to temp file, then atomic rename.
      final tempLocalPath = '$localPath.sync_tmp';
      final tempFile = File(tempLocalPath);
      await tempFile.parent.create(recursive: true);

      // ── Byte-level resume: check for existing partial download ──
      int resumeOffset = 0;
      if (await tempFile.exists()) {
        resumeOffset = await tempFile.length();
        _log.info(
          'Found partial download for $remotePath: $resumeOffset bytes',
        );
      }

      final remoteFile = await sftp.open(remotePath);
      try {
        final remoteStat = await remoteFile.stat();
        final remoteSize = remoteStat.size ?? 0;

        // Validate resume offset against remote file size.
        if (resumeOffset >= remoteSize && remoteSize > 0) {
          // Temp file is same size or larger — something changed, restart.
          resumeOffset = 0;
        }

        final FileMode writeMode;
        if (resumeOffset > 0) {
          writeMode = FileMode.append;
          _log.info(
            'Resuming SFTP download of $remotePath from byte '
            '$resumeOffset / $remoteSize',
          );
        } else {
          writeMode = FileMode.write;
        }

        final sink = tempFile.openWrite(mode: writeMode);
        int read = resumeOffset;
        bool cancelled = false;

        final readStream = resumeOffset > 0
            ? remoteFile.read(offset: resumeOffset)
            : remoteFile.read();
        await for (final chunk in readStream) {
          if (cancel != null && cancel.isCancelled) {
            cancelled = true;
            break;
          }
          sink.add(chunk);
          read += chunk.length;
          onProgress?.call(read);
        }
        await sink.flush();
        await sink.close();

        if (cancelled) {
          _log.info('Download cancelled: $remotePath (at $read bytes)');
          // Leave temp file for resume on next attempt.
          return 'Cancelled';
        }

        // Atomic rename (copy+delete fallback).
        try {
          await tempFile.rename(localPath);
        } catch (_) {
          await tempFile.copy(localPath);
          await tempFile.delete();
        }

        // Restore modification time from remote.
        final localFile = File(localPath);
        if (remoteStat.modifyTime != null) {
          try {
            await localFile.setLastModified(
                DateTime.fromMillisecondsSinceEpoch(
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
