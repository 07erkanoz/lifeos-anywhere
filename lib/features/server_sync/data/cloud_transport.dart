import 'package:anyware/features/sync/data/cancellation_token.dart';
import 'package:anyware/features/sync/domain/sync_manifest.dart';

// ═══════════════════════════════════════════════════════════════════════════════
// Abstract Cloud Transport
// ═══════════════════════════════════════════════════════════════════════════════

/// Unified transport interface for all sync providers (SFTP, Google Drive, OneDrive).
///
/// Each provider implements this interface so that [ServerSyncService] can work
/// with any of them through a single code path.
abstract class CloudTransport {
  /// Establish connection / authenticate.
  Future<void> connect();

  /// Close the connection and release resources.
  Future<void> disconnect();

  /// Quick connectivity test. Returns `true` on success.
  Future<bool> testConnection();

  /// List entries (files and folders) in the given remote [path].
  ///
  /// Used by the remote folder browser and manifest builder.
  Future<List<RemoteEntry>> listDirectory(String path);

  /// Build a [SyncManifest] by recursively scanning [remotePath].
  ///
  /// [accountId] is embedded in the manifest's `deviceId` field.
  Future<SyncManifest> buildRemoteManifest(
    String remotePath,
    String accountId,
  );

  /// Upload a local file to the remote [remotePath].
  ///
  /// Returns `null` on success, or an error message string on failure.
  /// Supports cancellation via [cancel] and progress reporting via [onProgress].
  Future<String?> uploadFile(
    String localPath,
    String remotePath, {
    void Function(int bytesWritten)? onProgress,
    CancellationToken? cancel,
  });

  /// Download a remote file to the local [localPath].
  ///
  /// Returns `null` on success, or an error message string on failure.
  Future<String?> downloadFile(
    String remotePath,
    String localPath, {
    void Function(int bytesRead)? onProgress,
    CancellationToken? cancel,
  });

  /// Delete a file on the remote server.
  ///
  /// Returns `true` on success.
  Future<bool> deleteRemoteFile(String remotePath);

  /// Recursively create remote directories as needed.
  Future<void> ensureRemoteDir(String path);

  /// Fetch incremental changes since the last sync.
  ///
  /// [lastToken] is the opaque page/delta token from the previous call.
  /// Returns `null` if the provider doesn't support delta sync (e.g. SFTP),
  /// in which case the caller should fall back to full manifest comparison.
  Future<DeltaResult?> getDelta(String? lastToken) async => null;
}

// ═══════════════════════════════════════════════════════════════════════════════
// Remote Browser (used by the folder picker UI)
// ═══════════════════════════════════════════════════════════════════════════════

/// Minimal interface for browsing remote directory trees.
///
/// Implemented by all transports and also by [LanRemoteBrowser] for browsing
/// LAN device file systems over HTTP.
abstract class RemoteBrowser {
  /// List entries in the given [path]. Pass empty string for root listing.
  Future<List<RemoteEntry>> listDirectory(String path);

  /// The initial/root path shown in the folder picker.
  String get rootPath;
}

// ═══════════════════════════════════════════════════════════════════════════════
// Data models
// ═══════════════════════════════════════════════════════════════════════════════

/// A single entry (file or folder) in a remote directory listing.
class RemoteEntry {
  /// Display name (e.g. "Documents", "report.pdf").
  final String name;

  /// Full path or ID on the remote (provider-specific).
  final String path;

  /// Whether this entry is a directory.
  final bool isDirectory;

  /// File size in bytes. Null for directories.
  final int? size;

  /// Last modification time. Null if unavailable.
  final DateTime? modified;

  const RemoteEntry({
    required this.name,
    required this.path,
    required this.isDirectory,
    this.size,
    this.modified,
  });

  Map<String, dynamic> toJson() => {
        'name': name,
        'path': path,
        'isDir': isDirectory,
        if (size != null) 'size': size,
        if (modified != null) 'modified': modified!.toIso8601String(),
      };

  factory RemoteEntry.fromJson(Map<String, dynamic> json) {
    return RemoteEntry(
      name: json['name'] as String,
      path: json['path'] as String,
      isDirectory: json['isDir'] as bool? ?? false,
      size: json['size'] as int?,
      modified: json['modified'] != null
          ? DateTime.tryParse(json['modified'] as String)
          : null,
    );
  }

  @override
  String toString() => 'RemoteEntry($name, dir=$isDirectory)';
}

/// Result of a delta/incremental sync query.
class DeltaResult {
  /// List of file changes since the last token.
  final List<DeltaChange> changes;

  /// Opaque token to pass to the next [CloudTransport.getDelta] call.
  final String newToken;

  const DeltaResult({
    required this.changes,
    required this.newToken,
  });
}

/// A single change reported by the delta endpoint.
class DeltaChange {
  /// Relative path of the changed file.
  final String relativePath;

  /// Type of change.
  final DeltaChangeType type;

  /// File size after the change (null for deletions).
  final int? size;

  /// Modification time after the change (null for deletions).
  final DateTime? modified;

  /// Content hash after the change (null for deletions).
  final String? hash;

  const DeltaChange({
    required this.relativePath,
    required this.type,
    this.size,
    this.modified,
    this.hash,
  });
}

/// Kinds of changes returned by delta queries.
enum DeltaChangeType {
  /// File was created or modified.
  modified,

  /// File was deleted.
  deleted,
}
