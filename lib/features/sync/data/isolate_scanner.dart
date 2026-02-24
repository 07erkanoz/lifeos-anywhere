import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:path/path.dart' as p;

import 'package:anyware/features/sync/data/sync_filter_utils.dart';
import 'package:anyware/features/sync/domain/sync_manifest.dart';

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

  const ScanResult({required this.entries, required this.fullPaths});
}

/// Runs directory scanning + optional hashing in a background isolate.
///
/// This keeps the main isolate free for UI rendering and network I/O.
Future<ScanResult> scanDirectoryInIsolate(ScanParams params) {
  return compute(_scanDirectory, params);
}

/// Top-level function that runs inside the isolate.
///
/// MUST NOT capture any closures or reference Ref/providers.
/// Uses synchronous I/O (fine inside a dedicated isolate).
ScanResult _scanDirectory(ScanParams params) {
  final dir = Directory(params.dirPath);
  if (!dir.existsSync()) {
    return const ScanResult(entries: [], fullPaths: {});
  }

  final entries = <SyncManifestEntry>[];
  final fullPaths = <String, String>{};

  // Synchronous listing is fine inside a dedicated isolate.
  final List<FileSystemEntity> entities;
  try {
    entities = dir.listSync(recursive: true);
  } catch (_) {
    return const ScanResult(entries: [], fullPaths: {});
  }

  for (final entity in entities) {
    if (entity is! File) continue;

    final relPath =
        p.relative(entity.path, from: params.dirPath).replaceAll(r'\', '/');

    // Apply include/exclude filters.
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

      // Compute SHA-256 for small-enough files.
      if (params.hashThresholdBytes > 0 &&
          stat.size <= params.hashThresholdBytes &&
          stat.size > 0) {
        final bytes = entity.readAsBytesSync();
        hash = sha256.convert(bytes).toString();
      }

      entries.add(SyncManifestEntry(
        relativePath: relPath,
        size: stat.size,
        lastModified: stat.modified.toUtc(),
        hash: hash,
      ));
      fullPaths[relPath] = entity.path;
    } catch (_) {
      // Skip files that cannot be stat'd or read (permission errors, etc.).
    }
  }

  return ScanResult(entries: entries, fullPaths: fullPaths);
}
