import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:anyware/core/logger.dart';
import 'package:anyware/features/sync/data/isolate_scanner.dart'
    show isSyncTempPath;
import 'package:anyware/features/server_sync/domain/sftp_server_config.dart';
import 'package:anyware/features/sync/data/cancellation_token.dart';
import 'package:anyware/features/sync/domain/sync_manifest.dart';

final _log = AppLogger('SftpTransport');

/// Encapsulates all SFTP operations: connect, list, upload, download, delete.
///
/// Stateless — call [connect] to obtain a session, then pass it to other
/// methods. The caller is responsible for closing the session.
class SftpTransport {
  SftpTransport({SftpHostKeyStore? hostKeyStore})
      : hostKeys = hostKeyStore ?? SftpHostKeyStore();

  /// Pinned host keys (trust-on-first-use).
  final SftpHostKeyStore hostKeys;

  // ═══════════════════════════════════════════════════════════════════════════
  // Connection
  // ═══════════════════════════════════════════════════════════════════════════

  /// Open an SSH + SFTP session to [server].
  ///
  /// Host keys are pinned trust-on-first-use: the first successful connect
  /// stores the server's host-key fingerprint for this account; a later
  /// connect with a different key is refused with
  /// [SftpHostKeyChangedException] (see [resetHostKey]).
  Future<SftpSession> connect(SftpServerConfig server) async {
    _log.info('Connecting to ${server.host}:${server.port}');
    final pinKey = SftpHostKeyStore.keyFor(server);
    final pinned = await hostKeys.get(pinKey);
    String? presented;

    final socket = await SSHSocket.connect(server.host, server.port,
        timeout: const Duration(seconds: 15));

    final client = SSHClient(
      socket,
      username: server.username,
      onVerifyHostKey: (type, fingerprint) {
        presented = SftpHostKeyStore.formatFingerprint(type, fingerprint);
        return pinned == null || pinned == presented;
      },
      onPasswordRequest: server.authMethod == 'password'
          ? () => server.password
          : null,
      identities: server.authMethod == 'key' && server.privateKey != null
          ? _parseIdentities(server.privateKey!, server.passphrase)
          : null,
    );

    final SftpClient sftp;
    try {
      sftp = await client.sftp();
    } catch (e) {
      client.close();
      if (pinned != null && presented != null && presented != pinned) {
        throw SftpHostKeyChangedException(
          host: server.host,
          port: server.port,
          expected: pinned,
          actual: presented!,
        );
      }
      rethrow;
    }

    if (pinned == null && presented != null) {
      await hostKeys.set(pinKey, presented!);
      _log.info('Pinned host key for ${server.host}: $presented');
    }
    _log.info('SFTP session established to ${server.host}');
    return SftpSession(client: client, sftp: sftp);
  }

  /// Forget the pinned host key(s) of account [accountId] so the next
  /// connect trusts whatever key the server presents (call after the user
  /// confirmed a legitimate server key change).
  Future<void> resetHostKey(String accountId) =>
      hostKeys.removeAccount(accountId);

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
    // A listing failure anywhere propagates: a partial remote listing must
    // never be used as the authoritative state (it would look like deletes).
    final List<SftpName> items;
    try {
      items = await sftp.listdir(currentPath);
    } catch (e) {
      throw SftpListingException(currentPath, e);
    }
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
        if (isSyncTempPath(name)) continue;
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
              // Unknown mtime: compare by size/hash only (see diff engine).
              : DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
        ));
      }
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // File operations
  // ═══════════════════════════════════════════════════════════════════════════

  /// Upload a local file to [remotePath].
  ///
  /// Writes `<remotePath>.sync_tmp` and then replaces the target. Byte-level
  /// resume only happens when the sidecar `<remotePath>.sync_tmp.meta`
  /// proves the partial temp file belongs to the same version (size + mtime)
  /// of the local file; otherwise the upload restarts.
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
      final slash = remotePath.lastIndexOf('/');
      if (slash > 0) {
        await ensureRemoteDir(sftp, remotePath.substring(0, slash));
      }

      final localFile = File(localPath);
      final localStat = await localFile.stat();
      if (localStat.type != FileSystemEntityType.file) {
        return 'Local file not found: $localPath';
      }
      final fileSize = localStat.size;
      final sourceTag = _versionTag(
          fileSize, localStat.modified.millisecondsSinceEpoch);

      final tempRemotePath = '$remotePath.sync_tmp';
      final metaRemotePath = '$tempRemotePath.meta';

      // Recover from a crash in the middle of a previous replace.
      await _recoverBackup(sftp, remotePath);

      // ── Byte-level resume, only onto a temp file of the same version ──
      int resumeOffset = 0;
      try {
        final remoteSize = (await sftp.stat(tempRemotePath)).size ?? 0;
        if (remoteSize > 0 && remoteSize < fileSize) {
          final tag = await _readRemoteText(sftp, metaRemotePath);
          if (tag == sourceTag) {
            resumeOffset = remoteSize;
            _log.info('Resuming SFTP upload of $remotePath at '
                '$resumeOffset / $fileSize bytes');
          }
        }
      } catch (_) {
        // No temp file — fresh upload.
      }
      if (resumeOffset == 0) {
        await _writeRemoteText(sftp, metaRemotePath, sourceTag);
      }

      final remoteFile = await sftp.open(
        tempRemotePath,
        mode: resumeOffset > 0
            ? SftpFileOpenMode.create |
                SftpFileOpenMode.write |
                SftpFileOpenMode.append
            : SftpFileOpenMode.create |
                SftpFileOpenMode.write |
                SftpFileOpenMode.truncate,
      );

      int written = resumeOffset;
      try {
        final stream = localFile.openRead(resumeOffset);
        await for (final chunk in stream) {
          if (cancel != null && cancel.isCancelled) {
            _log.info('Upload cancelled: $localPath (at $written bytes)');
            // Leave temp + meta for resume on next attempt.
            return 'Cancelled';
          }
          await remoteFile.write(Stream.value(Uint8List.fromList(chunk)),
              offset: written);
          written += chunk.length;
          onProgress?.call(written);
        }
      } finally {
        await remoteFile.close();
      }

      // Verify the temp file before it replaces anything.
      final tempSize = (await sftp.stat(tempRemotePath)).size;
      if (tempSize != null && tempSize != fileSize) {
        try {
          await sftp.remove(tempRemotePath);
        } catch (_) {}
        return 'Upload size mismatch for $remotePath '
            '($tempSize != $fileSize bytes)';
      }

      // Set mtime on the temp file (survives the rename). SETSTAT with the
      // ACMODTIME flag needs BOTH times, otherwise the packet is malformed.
      try {
        final secs = localStat.modified.millisecondsSinceEpoch ~/ 1000;
        final atime = localStat.accessed.millisecondsSinceEpoch ~/ 1000;
        await sftp.setStat(tempRemotePath, SftpFileAttrs(
          accessTime: atime > 0 ? atime : secs,
          modifyTime: secs,
        ));
      } catch (_) {
        // Not critical — some servers don't support setstat.
      }

      await _replaceRemote(sftp, tempRemotePath, remotePath);
      try {
        await sftp.remove(metaRemotePath);
      } catch (_) {}
      _log.info('Uploaded $localPath → $remotePath ($fileSize bytes'
          '${resumeOffset > 0 ? ', resumed from $resumeOffset' : ''})');
      return null;
    } catch (e) {
      _log.error('Upload failed: $localPath → $remotePath: $e', error: e);
      return e.toString();
    }
  }

  /// Moves [tempPath] over [targetPath] without ever losing both.
  ///
  /// SFTP v3 RENAME fails when the target exists, and dartssh2 does not
  /// expose the `posix-rename@openssh.com` extension. So: move the target
  /// aside to `.sync_bak`, move the temp file in, then drop the backup —
  /// restoring the backup if the second rename fails.
  Future<void> _replaceRemote(
    SftpClient sftp,
    String tempPath,
    String targetPath,
  ) async {
    final bakPath = '$targetPath.sync_bak';
    bool targetExists;
    try {
      await sftp.stat(targetPath);
      targetExists = true;
    } catch (_) {
      targetExists = false;
    }

    if (!targetExists) {
      await sftp.rename(tempPath, targetPath);
      return;
    }

    try {
      await sftp.remove(bakPath); // stale backup (target exists, so safe)
    } catch (_) {}
    await sftp.rename(targetPath, bakPath);
    try {
      await sftp.rename(tempPath, targetPath);
    } catch (e) {
      _log.warning('SFTP rename failed ($tempPath → $targetPath): $e; '
          'restoring previous version');
      try {
        await sftp.rename(bakPath, targetPath);
      } catch (e2) {
        _log.error('Could not restore $bakPath → $targetPath: $e2');
      }
      rethrow;
    }
    try {
      await sftp.remove(bakPath);
    } catch (_) {}
  }

  /// If a previous replace crashed after moving the target aside, put the
  /// backup back; if both exist the backup is stale and is removed.
  Future<void> _recoverBackup(SftpClient sftp, String targetPath) async {
    final bakPath = '$targetPath.sync_bak';
    try {
      await sftp.stat(bakPath);
    } catch (_) {
      return; // no backup
    }
    try {
      await sftp.stat(targetPath);
      try {
        await sftp.remove(bakPath);
      } catch (_) {}
    } catch (_) {
      try {
        await sftp.rename(bakPath, targetPath);
        _log.info('Recovered $targetPath from $bakPath');
      } catch (_) {}
    }
  }

  Future<String?> _readRemoteText(SftpClient sftp, String path) async {
    try {
      final f = await sftp.open(path);
      try {
        final bytes = await f.readBytes(length: 4096);
        return utf8.decode(bytes).trim();
      } finally {
        await f.close();
      }
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeRemoteText(
      SftpClient sftp, String path, String text) async {
    try {
      final f = await sftp.open(
        path,
        mode: SftpFileOpenMode.create |
            SftpFileOpenMode.write |
            SftpFileOpenMode.truncate,
      );
      try {
        await f.writeBytes(Uint8List.fromList(utf8.encode(text)));
      } finally {
        await f.close();
      }
    } catch (_) {
      // Without a sidecar the next attempt simply restarts.
    }
  }

  static String _versionTag(int size, int? mtimeMs) => 'v1 $size ${mtimeMs ?? '-'}';

  /// Download a remote file to [localPath].
  ///
  /// Writes `<localPath>.sync_tmp`, verifies its size against the remote
  /// file, and only then renames it over [localPath]. Byte-level resume only
  /// happens when the sidecar `<localPath>.sync_tmp.meta` shows the partial
  /// file came from the same remote version (size + mtime).
  ///
  /// Returns `null` on success, or an error message on failure.
  Future<String?> downloadFile(
    SftpClient sftp,
    String remotePath,
    String localPath, {
    void Function(int bytesRead)? onProgress,
    CancellationToken? cancel,
  }) async {
    final tempFile = File('$localPath.sync_tmp');
    final metaFile = File('$localPath.sync_tmp.meta');
    try {
      await tempFile.parent.create(recursive: true);

      final remoteFile = await sftp.open(remotePath);
      try {
        final remoteStat = await remoteFile.stat();
        final remoteSize = remoteStat.size;
        final sourceTag = remoteStat.modifyTime == null || remoteSize == null
            ? null
            : _versionTag(remoteSize, remoteStat.modifyTime! * 1000);

        // ── Resume only onto a temp file of the same remote version ──
        int resumeOffset = 0;
        if (sourceTag != null && await tempFile.exists()) {
          final len = await tempFile.length();
          String? tag;
          try {
            tag = (await metaFile.readAsString()).trim();
          } catch (_) {}
          if (tag == sourceTag && len > 0 && len < remoteSize!) {
            resumeOffset = len;
            _log.info('Resuming SFTP download of $remotePath from byte '
                '$resumeOffset / $remoteSize');
          }
        }
        if (resumeOffset == 0) {
          if (sourceTag != null) {
            await metaFile.writeAsString(sourceTag, flush: true);
          } else if (await metaFile.exists()) {
            await metaFile.delete();
          }
        }

        final sink = tempFile.openWrite(
            mode: resumeOffset > 0 ? FileMode.append : FileMode.write);
        int read = resumeOffset;
        bool cancelled = false;
        try {
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
        } finally {
          await sink.close();
        }

        if (cancelled) {
          _log.info('Download cancelled: $remotePath (at $read bytes)');
          // Leave temp + meta for resume on next attempt.
          return 'Cancelled';
        }

        // Verify the temp file BEFORE it replaces the target.
        final got = await tempFile.length();
        if (remoteSize != null && got != remoteSize) {
          await _deleteQuietly(tempFile);
          await _deleteQuietly(metaFile);
          return 'Download size mismatch for $remotePath '
              '($got != $remoteSize bytes)';
        }

        // Restore modification time from remote (survives the rename).
        if (remoteStat.modifyTime != null) {
          try {
            await tempFile.setLastModified(DateTime.fromMillisecondsSinceEpoch(
              remoteStat.modifyTime! * 1000,
            ));
          } catch (_) {}
        }

        await replaceLocalFile(tempFile, localPath);
        await _deleteQuietly(metaFile);
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

/// Moves [source] over [targetPath], never leaving the target missing when
/// the move fails: the old target is kept as `.sync_bak` until the new file
/// is in place.
Future<void> replaceLocalFile(File source, String targetPath) async {
  final target = File(targetPath);
  try {
    // rename() replaces an existing file atomically on POSIX and Windows.
    await source.rename(targetPath);
    return;
  } catch (_) {
    // Cross-device or platform quirk — fall back below.
  }
  final bak = File('$targetPath.sync_bak');
  final hadTarget = await target.exists();
  if (hadTarget) {
    if (await bak.exists()) await bak.delete();
    await target.rename(bak.path);
  }
  try {
    await source.copy(targetPath);
    await source.delete();
  } catch (e) {
    if (hadTarget) {
      try {
        if (await target.exists()) await target.delete();
        await bak.rename(targetPath);
      } catch (_) {}
    }
    rethrow;
  }
  if (hadTarget) await _deleteQuietly(bak);
}

Future<void> _deleteQuietly(File f) async {
  try {
    if (await f.exists()) await f.delete();
  } catch (_) {}
}

/// Thrown when an SFTP directory listing fails part-way. The job must stop:
/// a partial listing is never authoritative for deletions.
class SftpListingException implements Exception {
  final String path;
  final Object cause;
  SftpListingException(this.path, this.cause);
  @override
  String toString() => 'Remote listing failed at $path: $cause';
}

/// Thrown when the server presents a host key different from the one pinned
/// on first connect (possible man-in-the-middle).
class SftpHostKeyChangedException implements Exception {
  final String host;
  final int port;
  final String expected;
  final String actual;
  SftpHostKeyChangedException({
    required this.host,
    required this.port,
    required this.expected,
    required this.actual,
  });
  @override
  String toString() =>
      'The SSH host key of $host:$port has CHANGED (expected $expected, got '
      '$actual). This can mean someone is intercepting the connection. '
      'If the server was legitimately reinstalled, reset the stored host key '
      'for this account and connect again.';
}

/// Trust-on-first-use store of SSH host-key fingerprints, per account and
/// host:port. Fingerprints are not secret, so SharedPreferences is fine.
///
/// dartssh2 (2.16) only hands the verify callback an MD5 digest of the host
/// key blob, so that is what is pinned (`<type> MD5:<hex>`).
class SftpHostKeyStore {
  static const _prefKey = 'sftp_host_keys_v1';

  static String keyFor(SftpServerConfig s) => '${s.id}@${s.host}:${s.port}';

  static String formatFingerprint(String type, Uint8List fp) {
    final hex = fp.map((b) => b.toRadixString(16).padLeft(2, '0')).join(':');
    return '$type MD5:$hex';
  }

  Future<Map<String, String>> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefKey);
    if (raw == null) return {};
    try {
      return (jsonDecode(raw) as Map<String, dynamic>)
          .map((k, v) => MapEntry(k, v as String));
    } catch (_) {
      return {};
    }
  }

  Future<void> _save(Map<String, String> map) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefKey, jsonEncode(map));
  }

  Future<String?> get(String key) async => (await _load())[key];

  Future<void> set(String key, String fingerprint) async {
    final map = await _load();
    map[key] = fingerprint;
    await _save(map);
  }

  /// Removes every pinned key of [accountId] (all host:port combinations).
  Future<void> removeAccount(String accountId) async {
    final map = await _load();
    map.removeWhere((k, _) => k.startsWith('$accountId@'));
    await _save(map);
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
