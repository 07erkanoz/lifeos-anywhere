import 'dart:convert';
import 'dart:io';

import 'package:anyware/core/logger.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:anyware/features/sync/domain/sync_manifest.dart';

/// Persists [SyncManifest] snapshots per sync job.
///
/// Each job stores two manifests:
///   - `<jobId>_local.json` — last known local state
///   - `<jobId>_remote.json` — last known remote state
///
/// These are used for delete detection and change tracking in bidirectional
/// sync. Stored in `<appSupportDir>/sync_manifests/`.
class SyncManifestStore {
  SyncManifestStore._();
  static final instance = SyncManifestStore._();

  static final _log = AppLogger('SyncManifestStore');
  String? _basePath;

  /// Returns the base directory for manifest storage, creating it if needed.
  Future<String> _getBasePath() async {
    if (_basePath != null) return _basePath!;
    final appDir = await getApplicationSupportDirectory();
    final dir = Directory(p.join(appDir.path, 'sync_manifests'));
    if (!dir.existsSync()) {
      await dir.create(recursive: true);
    }
    _basePath = dir.path;
    return _basePath!;
  }

  /// Saves the local manifest snapshot for a job.
  Future<void> saveLocalManifest(String jobId, SyncManifest manifest) async {
    await _saveManifest(jobId, 'local', manifest);
  }

  /// Saves the remote manifest snapshot for a job.
  Future<void> saveRemoteManifest(String jobId, SyncManifest manifest) async {
    await _saveManifest(jobId, 'remote', manifest);
  }

  /// Loads the previously saved local manifest for a job.
  /// Returns `null` if no manifest exists (first sync).
  Future<SyncManifest?> loadLocalManifest(String jobId) async {
    return _loadManifest(jobId, 'local');
  }

  /// Loads the previously saved remote manifest for a job.
  /// Returns `null` if no manifest exists (first sync).
  Future<SyncManifest?> loadRemoteManifest(String jobId) async {
    return _loadManifest(jobId, 'remote');
  }

  /// Deletes all manifest data for a job (e.g. when the job is deleted).
  Future<void> deleteManifests(String jobId) async {
    try {
      final basePath = await _getBasePath();
      final localFile = File(p.join(basePath, '${jobId}_local.json'));
      final remoteFile = File(p.join(basePath, '${jobId}_remote.json'));
      if (localFile.existsSync()) await localFile.delete();
      if (remoteFile.existsSync()) await remoteFile.delete();
      final checkpointFile =
          File(p.join(basePath, '${jobId}_checkpoint.json'));
      if (checkpointFile.existsSync()) await checkpointFile.delete();
      _log.debug('Deleted manifests for job $jobId');
    } catch (e) {
      _log.warning('Failed to delete manifests for job $jobId: $e');
    }
  }

  // ── Checkpoint ──

  /// Saves a file-level checkpoint for a sync job.
  /// [index] is the 0-based index of the last successfully processed file.
  Future<void> saveCheckpoint(String jobId, int index) async {
    try {
      final basePath = await _getBasePath();
      final file = File(p.join(basePath, '${jobId}_checkpoint.json'));
      await file.writeAsString(jsonEncode({'lastIndex': index}));
    } catch (e) {
      _log.warning('Failed to save checkpoint for job $jobId: $e');
    }
  }

  /// Loads the last checkpoint for a sync job.
  /// Returns -1 if no checkpoint exists.
  Future<int> loadCheckpoint(String jobId) async {
    try {
      final basePath = await _getBasePath();
      final file = File(p.join(basePath, '${jobId}_checkpoint.json'));
      if (!file.existsSync()) return -1;
      final json =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      return json['lastIndex'] as int? ?? -1;
    } catch (e) {
      _log.warning('Failed to load checkpoint for job $jobId: $e');
      return -1;
    }
  }

  /// Deletes the checkpoint file for a job (on successful completion).
  Future<void> deleteCheckpoint(String jobId) async {
    try {
      final basePath = await _getBasePath();
      final file = File(p.join(basePath, '${jobId}_checkpoint.json'));
      if (file.existsSync()) await file.delete();
    } catch (_) {}
  }

  // ── Internal ──

  Future<void> _saveManifest(
    String jobId,
    String side,
    SyncManifest manifest,
  ) async {
    try {
      final basePath = await _getBasePath();
      final file = File(p.join(basePath, '${jobId}_$side.json'));
      final json = jsonEncode(manifest.toJson());
      await file.writeAsString(json);
      _log.debug(
        'Saved $side manifest for job $jobId '
        '(${manifest.entries.length} entries)',
      );
    } catch (e) {
      _log.warning('Failed to save $side manifest for job $jobId: $e');
    }
  }

  Future<SyncManifest?> _loadManifest(String jobId, String side) async {
    try {
      final basePath = await _getBasePath();
      final file = File(p.join(basePath, '${jobId}_$side.json'));
      if (!file.existsSync()) return null;
      final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      return SyncManifest.fromJson(json);
    } catch (e) {
      _log.warning('Failed to load $side manifest for job $jobId: $e');
      return null;
    }
  }
}
