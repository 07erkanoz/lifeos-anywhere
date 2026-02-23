// Manifest model for bidirectional sync.
//
// A manifest is a snapshot of all files in a sync directory at a point in
// time. Comparing two manifests (local vs remote) produces a diff that
// drives the bidirectional sync engine.

/// A single file entry within a [SyncManifest].
class SyncManifestEntry {
  /// Path relative to the sync base directory (always uses `/` separators).
  final String relativePath;

  /// File size in bytes.
  final int size;

  /// UTC last-modified timestamp (milliseconds since epoch for precision).
  final DateTime lastModified;

  /// Optional content hash (SHA-256 hex). Populated during local scan when
  /// the file is small enough; otherwise left null and size+date are used
  /// for comparison.
  final String? hash;

  const SyncManifestEntry({
    required this.relativePath,
    required this.size,
    required this.lastModified,
    this.hash,
  });

  Map<String, dynamic> toJson() => {
        'relativePath': relativePath,
        'size': size,
        'lastModified': lastModified.toIso8601String(),
        if (hash != null) 'hash': hash,
      };

  factory SyncManifestEntry.fromJson(Map<String, dynamic> json) {
    return SyncManifestEntry(
      relativePath: json['relativePath'] as String,
      size: json['size'] as int,
      lastModified: DateTime.parse(json['lastModified'] as String),
      hash: json['hash'] as String?,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SyncManifestEntry &&
          relativePath == other.relativePath &&
          size == other.size &&
          lastModified == other.lastModified;

  @override
  int get hashCode => Object.hash(relativePath, size, lastModified);
}

/// A complete manifest for a device's sync directory.
class SyncManifest {
  /// ID of the device that produced this manifest.
  final String deviceId;

  /// Absolute base path on the originating device.
  final String basePath;

  /// UTC timestamp when this manifest was created.
  final DateTime createdAt;

  /// All files found under [basePath].
  final List<SyncManifestEntry> entries;

  const SyncManifest({
    required this.deviceId,
    required this.basePath,
    required this.createdAt,
    this.entries = const [],
  });

  /// Build a fast lookup map keyed by relative path.
  Map<String, SyncManifestEntry> toMap() {
    return {for (final e in entries) e.relativePath: e};
  }

  Map<String, dynamic> toJson() => {
        'deviceId': deviceId,
        'basePath': basePath,
        'createdAt': createdAt.toIso8601String(),
        'entries': entries.map((e) => e.toJson()).toList(),
      };

  factory SyncManifest.fromJson(Map<String, dynamic> json) {
    return SyncManifest(
      deviceId: json['deviceId'] as String,
      basePath: json['basePath'] as String,
      createdAt: DateTime.parse(json['createdAt'] as String),
      entries: (json['entries'] as List<dynamic>)
          .map((e) => SyncManifestEntry.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }
}
