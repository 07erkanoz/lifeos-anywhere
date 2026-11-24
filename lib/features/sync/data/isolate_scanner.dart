import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:path/path.dart' as p;

import 'package:anyware/features/sync/data/sync_filter_utils.dart';
import 'package:anyware/features/sync/domain/sync_manifest.dart';

/// Suffixes of the temporary / staging files the sync engines write next to
/// real files. They are never part of a manifest on either side, otherwise a
/// half-written temp file would be synced (or deleted) like user data.
const syncTempSuffixes = <String>[
  '.sync_tmp',
  '.sync_tmp.meta',
  '.sync_dl',
  '.sync_bak',
  '.gdrive_tmp',
  '.onedrive_tmp',
];

/// Whether [path] (relative or absolute) names a sync temp/staging file.
bool isSyncTempPath(String path) {
  for (final s in syncTempSuffixes) {
    if (path.endsWith(s)) return true;
  }
  return false;
}

/// Thrown when a scan cannot produce a trustworthy manifest (root folder
/// missing or unreadable). Callers must treat this as a failed job — never as
/// an empty folder, because an empty manifest turns into "delete everything on
/// the other side" in a bidirectional diff.
class ScanException implements Exception {
  final String message;
  const ScanException(this.message);
  @override
  String toString() => 'ScanException: $message';
}

/// Parameters for the isolate scan function.
///
/// Must be a plain class (no closures) so it can cross the isolate boundary.
class ScanParams {
  final String dirPath;
  final List<String> includePatterns;
  final List<String> excludePatterns;

  /// Files <= this size (bytes) get SHA-256 hashed. 0 = skip hashing.
  final int hashThresholdBytes;

  const ScanParams({
    required this.dirPath,
    this.includePatterns = const [],
    this.excludePatterns = const [],
    this.hashThresholdBytes = 0,
  });
}

/// Result from the isolate scan.
class ScanResult {
  final List<SyncManifestEntry> entries;

  /// Maps relativePath → absolute path (needed by callers to resolve files).
  final Map<String, String> fullPaths;

  /// Relative paths (`/` separators) of sub-directories that could not be
  /// listed. Their contents are UNKNOWN — not deleted — so callers must not
  /// derive deletions for anything under them.
  final List<String> skippedDirs;

  /// Relative paths of files that were listed but could not be stat'd/read.
  /// Same rule: unknown, not deleted.
  final List<String> skippedFiles;

  const ScanResult({
    required this.entries,
    required this.fullPaths,
    this.skippedDirs = const [],
    this.skippedFiles = const [],
  });

  bool get isPartial => skippedDirs.isNotEmpty || skippedFiles.isNotEmpty;

  /// All paths/prefixes whose state is unknown after this scan.
  List<String> get unknownPaths => [...skippedDirs, ...skippedFiles];
}

/// Runs directory scanning + optional hashing in a background isolate.
///
/// Throws [ScanException] if the root folder is missing or unreadable.
/// Unreadable sub-folders are skipped and reported in
/// [ScanResult.skippedDirs].
Future<ScanResult> scanDirectoryInIsolate(ScanParams params) {
  return compute(scanDirectorySync, params);
}

/// Synchronous scan (the function run inside the isolate). Exposed for tests.
///
/// MUST NOT capture any closures or reference Ref/providers.
ScanResult scanDirectorySync(ScanParams params) {
  final root = Directory(params.dirPath);
  if (!root.existsSync()) {
    throw ScanException('Folder does not exist: ${params.dirPath}');
  }

  final entries = <SyncManifestEntry>[];
  final fullPaths = <String, String>{};
  final skippedDirs = <String>[];
  final skippedFiles = <String>[];

  // Resolved paths of directories already visited (symlink cycle guard).
  final visited = <String>{};

  String rel(String path) =>
      p.relative(path, from: params.dirPath).replaceAll(r'\', '/');

  // Iterative depth-first walk so that one unreadable folder only loses
  // that folder, never the whole manifest.
  final stack = <Directory>[root];
  var isRoot = true;
  while (stack.isNotEmpty) {
    final dir = stack.removeLast();
    final List<FileSystemEntity> children;
    try {
      final resolved = dir.resolveSymbolicLinksSync();
      if (!visited.add(resolved)) continue;
      children = dir.listSync(recursive: false, followLinks: true);
    } catch (e) {
      if (isRoot) {
        throw ScanException('Cannot read folder ${params.dirPath}: $e');
      }
      skippedDirs.add(rel(dir.path));
      continue;
    } finally {
      isRoot = false;
    }

    for (final entity in children) {
      if (entity is Directory) {
        stack.add(entity);
        continue;
      }
      if (entity is! File) continue;

      final relPath = rel(entity.path);
      if (isSyncTempPath(relPath)) continue;

      if (!matchesSyncFilters(
        relPath,
        includePatterns: params.includePatterns,
        excludePatterns: params.excludePatterns,
      )) {
        continue;
      }

      try {
        final stat = entity.statSync();
        String? hash;
        if (params.hashThresholdBytes > 0 &&
            stat.size <= params.hashThresholdBytes &&
            stat.size > 0) {
          hash = sha256.convert(entity.readAsBytesSync()).toString();
        }
        entries.add(SyncManifestEntry(
          relativePath: relPath,
          size: stat.size,
          lastModified: stat.modified.toUtc(),
          hash: hash,
        ));
        fullPaths[relPath] = entity.path;
      } catch (_) {
        // Unreadable file: its state is unknown, which is not "deleted".
        skippedFiles.add(relPath);
      }
    }
  }

  return ScanResult(
    entries: entries,
    fullPaths: fullPaths,
    skippedDirs: skippedDirs,
    skippedFiles: skippedFiles,
  );
}
