import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:anyware/core/background_service.dart';
import 'package:anyware/core/logger.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:flutter/material.dart' show TimeOfDay;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';
import 'package:watcher/watcher.dart';

import 'package:anyware/i18n/app_localizations.dart';
import 'package:anyware/features/discovery/domain/device.dart';
import 'package:anyware/features/discovery/presentation/providers.dart';
import 'package:anyware/features/settings/data/settings_repository.dart';
import 'package:anyware/features/sync/domain/sync_state.dart';
import 'package:anyware/features/sync/domain/sync_manifest.dart';
import 'package:anyware/features/sync/data/sync_sender.dart';
import 'package:anyware/features/sync/data/sync_diff_engine.dart';
import 'package:anyware/features/sync/data/sync_filter_utils.dart';
import 'package:anyware/features/sync/data/sync_manifest_store.dart';
import 'package:anyware/features/sync/data/isolate_scanner.dart';
import 'package:anyware/features/settings/presentation/providers.dart';
import 'package:anyware/features/sync/data/cancellation_token.dart';

// ═══════════════════════════════════════════════════════════════════════════════
// Provider
// ═══════════════════════════════════════════════════════════════════════════════

final syncServiceProvider =
    StateNotifierProvider<SyncService, SyncState>((ref) {
  return SyncService(ref);
});

// ═══════════════════════════════════════════════════════════════════════════════
// SyncService — multi-job sync manager
// ═══════════════════════════════════════════════════════════════════════════════

class SyncService extends StateNotifier<SyncState> {
  SyncService(this.ref) : super(const SyncState()) {
    _loadSavedJobs();
    _loadPairings();
    _autoResumeJobs();
  }

  static final _log = AppLogger('SyncService');
  static const _uuid = Uuid();

  final Ref ref;

  /// Maximum retry attempts for failed sync files.
  static const int _maxRetries = 2;

  /// SharedPreferences key for persisted job list.
  static const _prefSyncJobs = 'sync_jobs_v3';
  static const _prefSyncJobsV2 = 'sync_jobs_v2';
  static const _prefSyncPairings = 'sync_pairings_v1';

  // ─── Per-job runtime state (not serialised) ───
  final Map<String, StreamSubscription<WatchEvent>> _watchers = {};
  final Map<String, Timer?> _debounceTimers = {};
  final Map<String, Timer?> _scheduleTimers = {};
  final Map<String, Set<String>> _pendingFiles = {};
  final Map<String, DateTime> _lastPingTimes = {};
  final Map<String, SyncManifest> _pendingManifests = {};
  final Map<String, CancellationToken> _cancelTokens = {};

  // ─── Notification callbacks (set by providers.dart) ───
  void Function(String jobName, int fileCount, String deviceName)?
      onSyncBatchCompleted;

  /// Called when the first file of a sync batch is received from a remote device.
  void Function(String senderName)? onSyncReceivingStarted;

  /// Completer for the pending sync setup request.
  /// When the user accepts/rejects, this completer is completed with the result.
  Completer<Map<String, dynamic>>? _setupCompleter;

  // ═══════════════════════════════════════════════════════════════════════════
  // Persistence
  // ═══════════════════════════════════════════════════════════════════════════

  Future<void> _loadSavedJobs() async {
    try {
      final prefs = ref.read(sharedPreferencesProvider);

      // Try v3 first, then migrate from v2 if needed.
      var raw = prefs.getString(_prefSyncJobs);
      if (raw == null) {
        raw = prefs.getString(_prefSyncJobsV2);
        if (raw != null) {
          _log.info('Migrating sync jobs from v2 to v3');
          // v2 data deserializes into v3 via default values in fromJson.
          await prefs.setString(_prefSyncJobs, raw);
          await prefs.remove(_prefSyncJobsV2);
        }
      }
      if (raw == null) return;

      final list = (jsonDecode(raw) as List<dynamic>)
          .map((e) => SyncJob.fromJson(e as Map<String, dynamic>))
          .toList();

      state = state.copyWith(jobs: list);

      // Start schedule timers for enabled schedules.
      for (final job in list) {
        if (job.schedule != null && job.schedule!.enabled) {
          _startScheduleTimer(job);
        }
      }
    } catch (e) {
      _log.warning('Failed to load saved sync jobs: $e');
    }
  }

  Future<void> _saveJobs() async {
    try {
      final prefs = ref.read(sharedPreferencesProvider);
      final json = state.jobs.map((j) => j.toJson()).toList();
      await prefs.setString(_prefSyncJobs, jsonEncode(json));
    } catch (e) {
      _log.warning('Failed to save sync jobs: $e');
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Pairing persistence
  // ═══════════════════════════════════════════════════════════════════════════

  Future<void> _loadPairings() async {
    try {
      final prefs = ref.read(sharedPreferencesProvider);
      final raw = prefs.getString(_prefSyncPairings);
      if (raw == null) return;

      final list = (jsonDecode(raw) as List<dynamic>)
          .map((e) => SyncPairing.fromJson(e as Map<String, dynamic>))
          .toList();

      // Clean up stale pairings whose folders no longer exist.
      final valid = <SyncPairing>[];
      for (final p in list) {
        final folder = Directory(p.receiveFolder);
        if (await folder.exists()) {
          valid.add(p);
        } else {
          try {
            await folder.create(recursive: true);
            valid.add(p);
          } catch (e) {
            _log.warning('Removing stale pairing "${p.jobName}" — '
                'folder ${p.receiveFolder} missing: $e');
          }
        }
      }

      state = state.copyWith(pairings: valid);
      _log.info('Loaded ${valid.length} sync pairings '
          '(${list.length - valid.length} stale removed)');

      if (valid.length != list.length) await _savePairings();
    } catch (e) {
      _log.warning('Failed to load sync pairings: $e');
    }
  }

  Future<void> _savePairings() async {
    try {
      final prefs = ref.read(sharedPreferencesProvider);
      final json = state.pairings.map((p) => p.toJson()).toList();
      await prefs.setString(_prefSyncPairings, jsonEncode(json));
    } catch (e) {
      _log.warning('Failed to save sync pairings: $e');
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Auto-resume previously active jobs on app startup
  // ═══════════════════════════════════════════════════════════════════════════

  /// Automatically resumes sync jobs that were running before the app closed.
  /// Waits a few seconds for discovery service to initialise so device IPs
  /// are available.
  Future<void> _autoResumeJobs() async {
    // Give the discovery service time to start and obtain the local IP.
    await Future.delayed(const Duration(seconds: 4));

    final toResume = state.jobs
        .where((j) => j.wasRunning && j.acceptedByReceiver)
        .toList();

    if (toResume.isEmpty) return;

    _log.info('Auto-resuming ${toResume.length} previously active job(s)');
    for (final job in toResume) {
      _log.info('  → Auto-resuming "${job.name}" (${job.id})');
      try {
        await startJob(job.id);
      } catch (e) {
        _log.warning('Failed to auto-resume job "${job.name}": $e');
      }
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Sync setup handshake (receiver side)
  // ═══════════════════════════════════════════════════════════════════════════

  /// Returns the pairing for a given job ID, or `null` if none exists.
  SyncPairing? getPairingForJob(String jobId) => state.findPairing(jobId);

  /// Handles an incoming sync setup request from a remote sender.
  ///
  /// If a pairing already exists for this job, auto-accepts (returns the
  /// existing receive folder). Otherwise sets the pending setup state and
  /// waits for the user to accept or reject via the dialog.
  Future<Map<String, dynamic>> handleSyncSetupRequest(
    SyncSetupRequest request,
  ) async {
    _log.info('handleSyncSetupRequest: jobId=${request.jobId}, '
        'from=${request.senderDeviceName}');

    // Check for existing pairing → auto-accept.
    final existingPairing = state.findPairing(request.jobId);
    if (existingPairing != null &&
        existingPairing.isActive &&
        existingPairing.senderDeviceId == request.senderDeviceId) {
      // Verify that the receive folder still exists (or can be created).
      final folder = Directory(existingPairing.receiveFolder);
      if (!await folder.exists()) {
        try {
          await folder.create(recursive: true);
        } catch (e) {
          _log.warning('Auto-accept failed: cannot create folder '
              '${existingPairing.receiveFolder}: $e');
          // Remove broken pairing and show dialog again.
          state = state.removePairing(request.jobId);
          await _savePairings();
          // Fall through to show dialog.
        }
      }

      // Re-check pairing (may have been removed above).
      final stillPaired = state.findPairing(request.jobId);
      if (stillPaired != null) {
        _log.info('Auto-accepting setup for job ${request.jobId} '
            '(existing pairing → ${stillPaired.receiveFolder})');
        return {
          'accepted': true,
          'receiveFolder': stillPaired.receiveFolder,
          'autoAccepted': true,
        };
      }
    }

    // No existing pairing — show dialog and wait for user response.
    _setupCompleter = Completer<Map<String, dynamic>>();
    state = state.copyWith(pendingSyncSetup: request);

    _log.info('Waiting for user to accept/reject setup for ${request.jobId}');

    try {
      // Wait up to 120 seconds for user response.
      final result = await _setupCompleter!.future.timeout(
        const Duration(seconds: 120),
        onTimeout: () {
          _log.warning('Setup request timed out for ${request.jobId}');
          state = state.copyWith(clearPendingSyncSetup: true);
          return {'accepted': false, 'reason': 'timeout'};
        },
      );
      return result;
    } catch (e) {
      _log.error('Setup request error: $e', error: e);
      state = state.copyWith(clearPendingSyncSetup: true);
      return {'accepted': false, 'reason': 'error: $e'};
    }
  }

  /// Called when the user accepts the pending sync setup request.
  ///
  /// Creates a [SyncPairing] and completes the HTTP response so the sender
  /// can start syncing files. No receiver-side job is created — the receiver
  /// only stores the pairing to know where to save incoming files.
  Future<void> acceptSyncSetup(String jobId, String receiveFolder) async {
    final pending = state.pendingSyncSetup;
    if (pending == null || pending.jobId != jobId) {
      _log.warning('acceptSyncSetup called but no matching pending request');
      return;
    }

    _log.info('User accepted sync setup: jobId=$jobId, folder=$receiveFolder');

    // Create the pairing (receiver remembers where to save files).
    final pairing = SyncPairing(
      jobId: jobId,
      jobName: pending.jobName,
      senderDeviceId: pending.senderDeviceId,
      senderDeviceName: pending.senderDeviceName,
      receiveFolder: receiveFolder,
      direction: pending.direction,
      acceptedAt: DateTime.now(),
    );

    state = state.addPairing(pairing);
    await _savePairings();

    // Ensure the receive folder exists.
    final dir = Directory(receiveFolder);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }

    // Clear pending state and complete the HTTP response.
    state = state.copyWith(clearPendingSyncSetup: true);
    _setupCompleter?.complete({
      'accepted': true,
      'receiveFolder': receiveFolder,
    });
    _setupCompleter = null;
  }

  /// Called when the user rejects the pending sync setup request.
  void rejectSyncSetup(String jobId) {
    _log.info('User rejected sync setup: jobId=$jobId');
    state = state.copyWith(clearPendingSyncSetup: true);
    _setupCompleter?.complete({'accepted': false, 'reason': 'rejected'});
    _setupCompleter = null;
  }

  /// Removes a pairing (receiver-side) and notifies the remote sender.
  Future<void> removePairing(String jobId) async {
    final pairing = state.findPairing(jobId);
    state = state.removePairing(jobId);
    await _savePairings();
    _log.info('Removed pairing for $jobId');

    // Best-effort: notify the remote sender.
    if (pairing != null) {
      final localId = _localDeviceId;
      _notifyRemotePairingRemoved(
        jobId,
        pairing.senderDeviceId,
        localId,
      );
    }
  }

  /// Convenience getter for local device ID.
  String get _localDeviceId {
    try {
      return ref.read(discoveryServiceProvider).valueOrNull?.localDevice.id ?? '';
    } catch (_) {
      return '';
    }
  }

  /// Called when a remote device notifies us that it removed a pairing/job.
  ///
  /// On the receiver side this removes the pairing; on the sender side this
  /// removes the corresponding job.
  void onRemotePairingRemoved(String jobId, String remoteDeviceId) {
    // Check if we have a pairing for this jobId (receiver side).
    final pairing = state.findPairing(jobId);
    if (pairing != null) {
      state = state.removePairing(jobId);
      _savePairings();
      _log.info('Remote removal: pairing $jobId removed '
          '(notified by $remoteDeviceId)');
      return;
    }

    // Check if we have a job for this jobId (sender side).
    // Delete the job entirely so both sides stay in sync.
    final job = state.jobs.cast<SyncJob?>().firstWhere(
          (j) => j!.id == jobId,
          orElse: () => null,
        );
    if (job != null) {
      _stopJobInternal(jobId);
      state = state.removeJob(jobId);
      _saveJobs();
      // Clean up manifest files.
      SyncManifestStore.instance.deleteManifests(jobId);
      _log.info('Remote removal: job $jobId deleted '
          '(notified by $remoteDeviceId)');
      return;
    }

    _log.info('Remote removal: no pairing or job found for $jobId');
  }

  /// Best-effort notification to the remote device that a pairing was removed.
  void _notifyRemotePairingRemoved(
    String jobId,
    String remoteDeviceId,
    String localDeviceId,
  ) {
    // Find the remote device by ID.
    try {
      final deviceList = ref.read(devicesProvider).valueOrNull ?? [];
      final remote = deviceList.cast<Device?>().firstWhere(
            (d) => d!.id == remoteDeviceId,
            orElse: () => null,
          );
      if (remote == null) {
        _log.info('Cannot notify remote ($remoteDeviceId) — not discovered');
        return;
      }

      final sender = ref.read(syncSenderProvider);
      sender.sendRemovePairing(
        remote,
        jobId: jobId,
        senderDeviceId: localDeviceId,
      );
    } catch (e) {
      _log.info('Failed to notify remote about pairing removal: $e');
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Job CRUD
  // ═══════════════════════════════════════════════════════════════════════════

  /// Creates a new sync job and persists it. Returns the job ID.
  Future<String> createJob({
    required String name,
    required String sourceDirectory,
    required Device target,
    SyncSchedule? schedule,
    SyncDirection syncDirection = SyncDirection.oneWay,
    ConflictStrategy conflictStrategy = ConflictStrategy.newerWins,
    SyncMode syncMode = SyncMode.general,
    List<String> includePatterns = const [],
    List<String> excludePatterns = const [],
    bool mirrorDeletions = true,
    String? remoteBaseDir,
    bool convertHeicToJpg = false,
    String dateSubfolderFormat = 'YYYY/MM',
  }) async {
    final job = SyncJob(
      id: _uuid.v4(),
      name: name,
      sourceDirectory: sourceDirectory,
      targetDeviceId: target.id,
      targetDeviceName: target.name,
      targetDeviceIp: target.ip,
      createdAt: DateTime.now(),
      schedule: schedule,
      syncDirection: syncDirection,
      conflictStrategy: conflictStrategy,
      syncMode: syncMode,
      includePatterns: includePatterns,
      excludePatterns: excludePatterns,
      mirrorDeletions: mirrorDeletions,
      remoteBaseDir: remoteBaseDir,
      convertHeicToJpg: convertHeicToJpg,
      dateSubfolderFormat: dateSubfolderFormat,
    );

    state = state.addJob(job);
    await _saveJobs();

    if (schedule != null && schedule.enabled) {
      _startScheduleTimer(job);
    }

    _log.info('Created sync job "${job.name}" (${job.id}) '
        '[${syncDirection.name}, ${syncMode.name}]');
    return job.id;
  }

  /// Deletes a sync job — stops it first if running.
  Future<void> deleteJob(String jobId) async {
    // Grab job info before removing so we can notify the remote device.
    final job = state.jobs.cast<SyncJob?>().firstWhere(
          (j) => j!.id == jobId,
          orElse: () => null,
        );

    _stopJobInternal(jobId);
    state = state.removeJob(jobId);
    await _saveJobs();
    // Clean up manifest files.
    await SyncManifestStore.instance.deleteManifests(jobId);
    _log.info('Deleted sync job $jobId');

    // Best-effort: notify the remote receiver.
    if (job != null) {
      _notifyRemotePairingRemoved(
        jobId,
        job.targetDeviceId,
        _localDeviceId,
      );
    }
  }

  /// Updates editable properties of a job.
  Future<void> updateJob(
    String jobId, {
    String? name,
    SyncSchedule? schedule,
    bool clearSchedule = false,
    SyncDirection? syncDirection,
    ConflictStrategy? conflictStrategy,
    SyncMode? syncMode,
    List<String>? includePatterns,
    List<String>? excludePatterns,
    bool? mirrorDeletions,
    String? remoteBaseDir,
    bool clearRemoteBaseDir = false,
    bool? convertHeicToJpg,
    String? dateSubfolderFormat,
  }) async {
    final job = _findJob(jobId);
    if (job == null) return;

    final updated = job.copyWith(
      name: name,
      schedule: schedule,
      clearSchedule: clearSchedule,
      syncDirection: syncDirection,
      conflictStrategy: conflictStrategy,
      syncMode: syncMode,
      includePatterns: includePatterns,
      excludePatterns: excludePatterns,
      mirrorDeletions: mirrorDeletions,
      remoteBaseDir: remoteBaseDir,
      clearRemoteBaseDir: clearRemoteBaseDir,
      convertHeicToJpg: convertHeicToJpg,
      dateSubfolderFormat: dateSubfolderFormat,
    );
    state = state.updateJob(updated);
    await _saveJobs();

    // Re-arm schedule timer.
    _scheduleTimers[jobId]?.cancel();
    _scheduleTimers.remove(jobId);
    if (updated.schedule != null && updated.schedule!.enabled) {
      _startScheduleTimer(updated);
    }
  }

  /// Navigates the UI to the detail screen of a job.
  void selectJob(String? jobId) {
    state = state.copyWith(
      activeJobId: jobId,
      clearActiveJobId: jobId == null,
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Sync control — per job
  // ═══════════════════════════════════════════════════════════════════════════

  /// Starts (or restarts) a sync job.
  Future<void> startJob(String jobId) async {
    var job = _findJob(jobId);
    if (job == null) return;
    if (job.phase == SyncJobPhase.syncing) return; // Already running.

    final dir = Directory(job.sourceDirectory);
    if (!await dir.exists()) {
      _updateJob(job.copyWith(phase: SyncJobPhase.error, status: 'sourceNotFound'));
      return;
    }

    // Create a fresh cancellation token for this sync session.
    _cancelTokens[jobId]?.cancel(); // Cancel any stale token.
    final cancelToken = CancellationToken();
    _cancelTokens[jobId] = cancelToken;

    // Reset runtime state.
    job = job.copyWith(
      phase: SyncJobPhase.syncing,
      status: 'syncInitialScan',
      fileItems: [],
      failedFiles: [],
      failedCount: 0,
      syncedCount: 0,
      totalBytes: 0,
      transferredBytes: 0,
      syncStartTime: DateTime.now(),
    );
    _updateJob(job);

    // Keep the device awake during sync operations.
    try {
      await WakelockPlus.enable();
    } catch (_) {}

    // Resolve target device IP from discovery.
    final targetDevice = _resolveDevice(job);
    if (targetDevice == null) {
      _updateJob(job.copyWith(phase: SyncJobPhase.error, status: 'syncCannotReach'));
      return;
    }

    // Ping check.
    final sender = ref.read(syncSenderProvider);
    final reachable = await sender.pingTarget(targetDevice);
    if (!reachable) {
      _updateJob(job.copyWith(phase: SyncJobPhase.error, status: 'syncCannotReach'));
      return;
    }
    _lastPingTimes[jobId] = DateTime.now();

    // ── Single scan: build manifest + collect pending files ──
    final sourceDir = job.sourceDirectory;
    _log.info('Job "$jobId": scanning source directory: $sourceDir');

    // Capture filter state before the scan loop so it remains non-null
    // even when `job` is re-fetched for pause/stop checks.
    final jobForFilter = job;

    final manifestEntries = <SyncManifestEntry>[];
    final allFilePaths = <String, String>{}; // relPath → fullPath

    try {
      // Scan in a background isolate to keep the UI responsive.
      final scanResult = await scanDirectoryInIsolate(ScanParams(
        dirPath: sourceDir,
        includePatterns: jobForFilter.includePatterns,
        excludePatterns: jobForFilter.excludePatterns,
        hashThresholdBytes: 50 * 1024 * 1024, // 50 MB
      ));
      manifestEntries.addAll(scanResult.entries);
      allFilePaths.addAll(scanResult.fullPaths);
    } catch (e) {
      _log.error('Initial scan failed for job $jobId: $e', error: e);
      final errJob = _findJob(jobId);
      if (errJob != null) {
        _updateJob(errJob.copyWith(
            phase: SyncJobPhase.error, status: 'Initial scan failed: $e'));
      }
      return;
    }

    // Re-fetch after the scan loop.
    job = _findJob(jobId);
    if (job == null) return;

    final discoveryService = ref.read(discoveryServiceProvider).valueOrNull;
    final deviceId = discoveryService?.localDevice.id ?? '';

    // Build current manifest snapshot.
    final currentManifest = SyncManifest(
      deviceId: deviceId,
      basePath: sourceDir,
      createdAt: DateTime.now().toUtc(),
      entries: manifestEntries,
    );

    // ── Incremental sync: compare with previous manifest ──
    // Only include files that are NEW or MODIFIED since the last successful
    // sync. On first sync (no saved manifest) all files are included.
    final store = SyncManifestStore.instance;
    final prevManifest = await store.loadLocalManifest(jobId);

    Set<String> pending;
    int scannedTotalSize = 0;

    if (prevManifest != null) {
      final prevMap = prevManifest.toMap();
      pending = <String>{};
      for (final entry in manifestEntries) {
        final prev = prevMap[entry.relativePath];
        final isChanged = prev == null ||
            prev.size != entry.size ||
            entry.lastModified.isAfter(prev.lastModified);
        if (isChanged) {
          final fullPath = allFilePaths[entry.relativePath];
          if (fullPath != null) {
            pending.add(fullPath);
            scannedTotalSize += entry.size;
          }
        }
      }
      _log.info('Job "$jobId": incremental sync — '
          '${pending.length} changed out of ${manifestEntries.length} total');
    } else {
      pending = allFilePaths.values.toSet();
      for (final e in manifestEntries) {
        scannedTotalSize += e.size;
      }
      _log.info('Job "$jobId": first sync — ${pending.length} files '
          '(${(scannedTotalSize / (1024 * 1024)).toStringAsFixed(1)} MB)');
    }

    _pendingFiles[jobId] = pending;

    // Store manifest snapshot so we can save it after sync completes.
    _pendingManifests[jobId] = currentManifest;

    // ── Sync handshake: always send setup request ──
    // The receiver auto-accepts if a pairing already exists, so this is
    // safe to call on every restart. It also notifies the receiver that a
    // new sync session is starting.
    {
      _updateJob(job.copyWith(status: 'syncSetupWaiting'));
      final localDevice = discoveryService?.localDevice;

      if (localDevice != null) {
        final setupResult = await sender.sendSyncSetupRequest(
          targetDevice,
          jobId: job.id,
          jobName: job.name,
          senderDeviceId: localDevice.id,
          senderDeviceName: localDevice.name,
          direction: job.syncDirection,
          fileCount: pending.length,
          totalSize: scannedTotalSize,
        );

        job = _findJob(jobId);
        if (job == null) return;

        if (setupResult != null) {
          final accepted = setupResult['accepted'] as bool? ?? false;
          if (!accepted) {
            _updateJob(job.copyWith(
              phase: SyncJobPhase.error,
              status: 'syncSetupRejected',
            ));
            return;
          }
          if (!job.acceptedByReceiver) {
            _updateJob(job.copyWith(acceptedByReceiver: true));
            await _saveJobs();
            job = _findJob(jobId);
            if (job == null) return;
          }
          _log.info('Setup accepted by ${targetDevice.name}: $setupResult');
        } else {
          _log.info('Setup request not supported by ${targetDevice.name}, '
              'falling back to direct sync');
        }
      }
    }

    // ── Branch: bidirectional vs one-way ──
    _log.info('Job "$jobId": handshake complete, '
        'direction=${job.syncDirection.name}, proceeding to sync');
    if (job.isBidirectional) {
      await _processBidirectionalSync(jobId, targetDevice, cancelToken);
      _startWatcher(jobId, job.sourceDirectory);
      return;
    }

    // ── One-way: process changed files ──
    if (pending.isNotEmpty) {
      _debounceTimers[jobId]?.cancel();
      _debounceTimers[jobId] =
          Timer(const Duration(milliseconds: 500), () => _processJobFiles(jobId, cancelToken));
    } else {
      _log.info('Job "$jobId": no changed files, going to watching state');
      // Save manifest even when nothing changed (confirms sync is up-to-date).
      await store.saveLocalManifest(jobId, currentManifest);
      _pendingManifests.remove(jobId);
      _updateJob(job.copyWith(
        phase: SyncJobPhase.watching,
        status: 'syncCompleted',
        lastSyncTime: DateTime.now(),
      ));
    }

    // Start watcher.
    _startWatcher(jobId, job.sourceDirectory);
  }

  /// Stops a running job — goes back to idle.
  void stopJob(String jobId) {
    _stopJobInternal(jobId);
    final job = _findJob(jobId);
    if (job == null) return;
    _updateJob(job.copyWith(
      phase: SyncJobPhase.idle,
      status: 'syncStopped',
      wasRunning: false,
    ));
    _saveJobs();
    _log.info('Stopped job $jobId');
  }

  /// Pauses a syncing or watching job — file sending pauses and watchers
  /// are suspended.
  void pauseJob(String jobId) {
    final job = _findJob(jobId);
    if (job == null) return;
    if (job.phase != SyncJobPhase.syncing &&
        job.phase != SyncJobPhase.watching) {
      return;
    }
    _updateJob(job.copyWith(phase: SyncJobPhase.paused, status: 'syncPaused'));
    // Suspend the watcher so no new file events are queued.
    _watchers[jobId]?.cancel();
    _watchers.remove(jobId);
    _log.info('Paused job $jobId');
  }

  /// Resumes a paused job.
  void resumeJob(String jobId) {
    final job = _findJob(jobId);
    if (job == null || job.phase != SyncJobPhase.paused) return;

    // Re-process pending items if there are any.
    final pendingItems = job.fileItems
        .where((f) => f.status == SyncFileStatus.pending)
        .toList();
    if (pendingItems.isNotEmpty) {
      _updateJob(job.copyWith(phase: SyncJobPhase.syncing, status: 'syncing'));
      _log.info('Resumed job $jobId (syncing ${pendingItems.length} pending)');
      final pending = _pendingFiles.putIfAbsent(jobId, () => <String>{});
      for (final item in pendingItems) {
        pending.add(p.join(job.sourceDirectory, item.relativePath));
      }
      _debounceTimers[jobId]?.cancel();
      _debounceTimers[jobId] =
          Timer(const Duration(milliseconds: 200), () => _processJobFiles(jobId, _cancelTokens[jobId]));
    } else {
      // No pending files — go back to watching.
      _updateJob(job.copyWith(phase: SyncJobPhase.watching, status: 'syncCompleted'));
      _log.info('Resumed job $jobId (watching)');
    }

    // Restart the watcher (was cancelled on pause).
    _startWatcher(jobId, job.sourceDirectory);
  }

  /// Skip a specific file in a job by index.
  void skipFile(String jobId, int index) {
    final job = _findJob(jobId);
    if (job == null || index < 0 || index >= job.fileItems.length) return;
    if (job.fileItems[index].status != SyncFileStatus.pending) return;
    final items = List<SyncFileItem>.from(job.fileItems);
    items[index] = items[index].copyWith(status: SyncFileStatus.skipped);
    _updateJob(job.copyWith(fileItems: items));
  }

  /// Stops all running jobs.
  void stopAll() {
    for (final job in state.jobs) {
      if (job.isActive || job.phase == SyncJobPhase.paused) {
        stopJob(job.id);
      }
    }
    // Belt-and-suspenders: cancel any leftover watchers / timers.
    for (final sub in _watchers.values) {
      sub.cancel();
    }
    _watchers.clear();
    for (final timer in _debounceTimers.values) {
      timer?.cancel();
    }
    _debounceTimers.clear();
    for (final timer in _scheduleTimers.values) {
      timer?.cancel();
    }
    _scheduleTimers.clear();
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Auto-sync on LAN device discovery (Faz 3.4)
  // ═══════════════════════════════════════════════════════════════════════════

  /// Minimum time between auto-sync triggers for the same job (minutes).
  static const _autoSyncCooldownMinutes = 30;

  /// Called when a device is discovered (or re-discovered) on the LAN.
  ///
  /// If auto-sync-on-LAN is enabled in settings, this starts any idle sync
  /// jobs that target the discovered device — provided enough time has elapsed
  /// since their last sync (cooldown).
  void onDeviceDiscovered(Device device) {
    final settings = ref.read(settingsProvider);
    if (!settings.autoSyncOnLan) return;

    for (final job in state.jobs) {
      if (job.targetDeviceId != device.id) continue;
      if (job.phase != SyncJobPhase.idle) continue;

      // Cooldown: skip if synced recently.
      if (job.lastSyncTime != null) {
        final elapsed = DateTime.now().difference(job.lastSyncTime!);
        if (elapsed.inMinutes < _autoSyncCooldownMinutes) continue;
      }

      _log.info(
        'Auto-sync triggered for "${job.name}" — '
        'device "${device.name}" discovered on LAN',
      );
      startJob(job.id);
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Receiver side
  // ═══════════════════════════════════════════════════════════════════════════

  /// Idle timeout timers per sender — when no new file arrives for 30 seconds,
  /// the session is marked as inactive (completed).
  final Map<String, Timer?> _receiverIdleTimers = {};

  /// Called when a sync file is received from a remote device.
  ///
  /// Populates [activeSyncSessions] for the UI and triggers notifications.
  /// When [jobId]/[jobName] are provided (new protocol), sessions are keyed
  /// per-job (`deviceId::jobId`) so each sync job gets its own card in the UI.
  void onFileReceived(
    String relativePath,
    String senderName,
    String savedPath, [
    String senderDeviceId = '',
    int fileSize = 0,
    String? jobId,
    String? jobName,
  ]) {
    _log.info('onFileReceived: $relativePath from $senderName '
        '(id: $senderDeviceId, size: $fileSize, '
        'jobId: $jobId, jobName: $jobName)');
    final wasReceiving = state.isReceiving;

    // Per-job session key: "deviceId::jobId" (job-aware) or "deviceId" (legacy).
    final deviceKey = senderDeviceId.isNotEmpty ? senderDeviceId : senderName;
    final key = (jobId != null && jobId.isNotEmpty)
        ? '$deviceKey::$jobId'
        : deviceKey;

    // Build a new file item.
    final newItem = SyncFileItem(
      relativePath: relativePath,
      status: SyncFileStatus.completed,
      completedAt: DateTime.now(),
      fileSize: fileSize,
    );

    // Update or create the session for this sender + job.
    final sessions = Map<String, ReceiverSyncSession>.from(
      state.activeSyncSessions,
    );
    final existing = sessions[key];

    if (existing != null) {
      sessions[key] = existing.copyWith(
        receivedItems: [...existing.receivedItems, newItem],
        receivedBytes: existing.receivedBytes + fileSize,
        isActive: true,
      );
    } else {
      sessions[key] = ReceiverSyncSession(
        senderDeviceId: senderDeviceId,
        senderName: senderName,
        startedAt: DateTime.now(),
        receivedItems: [newItem],
        receivedBytes: fileSize,
        isActive: true,
        jobId: jobId,
        jobName: jobName,
      );
    }

    state = state.copyWith(
      isReceiving: true,
      receiverSenderName: senderName,
      receivedItems: [...state.receivedItems, newItem],
      activeSyncSessions: sessions,
    );

    _log.info('Receiver state updated: ${sessions.length} sessions, '
        '${sessions[key]?.receivedItems.length ?? 0} files from $senderName '
        '(job: ${jobName ?? "legacy"})');

    // Notify on the first file of a new batch.
    if (!wasReceiving || (existing == null)) {
      _log.info('First file of new batch from $senderName — firing notification');
      onSyncReceivingStarted?.call(senderName);
    }

    // Reset idle timer for this session — if no new file arrives within
    // 30 seconds, mark the session as completed.
    _receiverIdleTimers[key]?.cancel();
    _receiverIdleTimers[key] = Timer(const Duration(seconds: 30), () {
      _completeReceiverSession(key);
    });
  }

  /// Marks a receiver session as completed (inactive), fires the
  /// batch-completed notification, and updates the pairing's last sync stats.
  void _completeReceiverSession(String key) {
    final sessions = Map<String, ReceiverSyncSession>.from(
      state.activeSyncSessions,
    );
    final session = sessions[key];
    if (session == null || !session.isActive) return;

    sessions[key] = session.copyWith(isActive: false);
    final hasActive = sessions.values.any((s) => s.isActive);

    state = state.copyWith(
      activeSyncSessions: sessions,
      isReceiving: hasActive,
    );

    // Update the pairing's last-sync statistics.
    if (session.jobId != null && session.jobId!.isNotEmpty) {
      final pairing = state.findPairing(session.jobId!);
      if (pairing != null) {
        state = state.updatePairing(pairing.copyWith(
          lastSyncTime: DateTime.now(),
          lastSyncFileCount: session.receivedItems.length,
          lastSyncTotalBytes: session.receivedBytes,
        ));
        _savePairings();
      }
    }

    // Fire summary notification — use job name if available.
    onSyncBatchCompleted?.call(
      session.jobName ?? 'Sync',
      session.receivedItems.length,
      session.senderName,
    );

    _log.info(
      'Receiver session completed: ${session.receivedItems.length} files '
      'from ${session.senderName} (job: ${session.jobName ?? "legacy"})',
    );
  }

  /// Clears completed (inactive) receiver sessions from the UI.
  void clearCompletedReceiverSessions() {
    final sessions = Map<String, ReceiverSyncSession>.from(
      state.activeSyncSessions,
    );
    sessions.removeWhere((_, s) => !s.isActive);
    state = state.copyWith(activeSyncSessions: sessions);
  }

  /// Returns the sync receive folder (for UI display).
  String getSyncReceiveFolder() {
    final settings = ref.read(settingsProvider);
    if (settings.syncReceiveFolder.isNotEmpty) {
      return settings.syncReceiveFolder;
    }
    return p.join(settings.downloadPath, 'Sync');
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Bidirectional sync
  // ═══════════════════════════════════════════════════════════════════════════

  /// Runs a full bidirectional sync cycle for the given job.
  ///
  /// Steps:
  /// 1. Build local manifest by scanning the source directory.
  /// 2. Fetch remote manifest from the target device.
  /// 3. Load previous manifests (for delete detection).
  /// 4. Compute diff plan.
  /// 5. Execute plan (send, pull, delete, handle conflicts).
  /// 6. Save new manifests for next run.
  Future<void> _processBidirectionalSync(
    String jobId,
    Device targetDevice,
    CancellationToken cancelToken,
  ) async {
    var job = _findJob(jobId);
    if (job == null) return;

    _updateJob(job.copyWith(status: 'syncBuildingManifest'));
    final sender = ref.read(syncSenderProvider);

    // ── 1. Build local manifest ──
    final localManifest = await _buildLocalManifest(job);
    if (localManifest == null) {
      _updateJob(job.copyWith(
        phase: SyncJobPhase.error,
        status: 'Failed to scan local directory',
      ));
      return;
    }

    // ── 2. Fetch remote manifest ──
    _updateJob(job.copyWith(status: 'syncFetchingRemoteManifest'));
    final discoveryService =
        ref.read(discoveryServiceProvider).valueOrNull;
    final localName = discoveryService?.localDevice.name ?? 'Unknown';

    final remoteManifest = await sender.getRemoteManifest(
      targetDevice,
      senderName: localName,
      basePath: job.remoteBaseDir,
      jobId: job.id,
      jobName: job.name,
    );

    if (remoteManifest == null) {
      _updateJob(job.copyWith(
        phase: SyncJobPhase.error,
        status: 'syncCannotReach',
      ));
      return;
    }

    // ── 3. Load previous manifests ──
    final store = SyncManifestStore.instance;
    final prevLocal = await store.loadLocalManifest(jobId);
    final prevRemote = await store.loadRemoteManifest(jobId);

    // ── 4. Compute diff ──
    _updateJob(job.copyWith(status: 'syncComputingDiff'));
    final plan = computeSyncPlan(
      local: localManifest,
      remote: remoteManifest,
      previousLocal: prevLocal,
      previousRemote: prevRemote,
      conflictStrategy: job.conflictStrategy,
      mirrorDeletions: job.mirrorDeletions,
    );

    _log.info('Job "$jobId" bidirectional plan: $plan '
        '(local=${localManifest.entries.length} files, '
        'remote=${remoteManifest.entries.length} files, '
        'prevLocal=${prevLocal?.entries.length ?? 0}, '
        'prevRemote=${prevRemote?.entries.length ?? 0})');

    if (plan.isEmpty) {
      _updateJob(job.copyWith(
        phase: SyncJobPhase.watching,
        status: 'syncCompleted',
        lastSyncTime: DateTime.now(),
      ));
      // Save manifests even if nothing to do (updates timestamps).
      await store.saveLocalManifest(jobId, localManifest);
      await store.saveRemoteManifest(jobId, remoteManifest);
      _saveJobs();
      return;
    }

    // ── 5. Handle conflicts (askUser strategy) ──
    if (plan.hasConflicts && job.conflictStrategy == ConflictStrategy.askUser) {
      final conflicts = plan.conflicts.map((a) => SyncConflict(
        relativePath: a.relativePath,
        localSize: a.localEntry?.size ?? 0,
        localModified: a.localEntry?.lastModified ?? DateTime.now(),
        remoteSize: a.remoteEntry?.size ?? 0,
        remoteModified: a.remoteEntry?.lastModified ?? DateTime.now(),
      )).toList();

      state = state.copyWith(pendingConflicts: conflicts);
      _updateJob(job.copyWith(status: 'syncWaitingConflictResolution'));

      // Wait for all conflicts to be resolved.
      while (state.pendingConflicts.any((c) => !c.isResolved)) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        job = _findJob(jobId);
        if (job == null || job.phase == SyncJobPhase.idle) return;
      }
    }

    // ── 6. Execute plan ──
    // Re-read job since it may have been modified during conflict resolution.
    job = _findJob(jobId);
    if (job == null) return;

    final allActions = <SyncAction>[
      ...plan.sends,
      ...plan.pulls,
      if (job.mirrorDeletions) ...plan.localDeletes,
      if (job.mirrorDeletions) ...plan.remoteDeletes,
    ];

    // For keepBoth conflicts, handle them as sends (local copy → remote with suffix).
    if (plan.hasConflicts && job.conflictStrategy == ConflictStrategy.keepBoth) {
      for (final conflict in plan.conflicts) {
        // Keep both: send local to remote with _conflict suffix,
        // pull remote to local with _conflict suffix.
        allActions.add(SyncAction(
          type: SyncActionType.sendToRemote,
          relativePath: conflict.relativePath,
          localEntry: conflict.localEntry,
          remoteEntry: conflict.remoteEntry,
        ));
      }
    }

    // For askUser resolved conflicts, add the resolved actions.
    if (plan.hasConflicts && job.conflictStrategy == ConflictStrategy.askUser) {
      for (final conflict in state.pendingConflicts) {
        if (conflict.resolution == 'local') {
          allActions.add(SyncAction(
            type: SyncActionType.sendToRemote,
            relativePath: conflict.relativePath,
          ));
        } else if (conflict.resolution == 'remote') {
          allActions.add(SyncAction(
            type: SyncActionType.pullFromRemote,
            relativePath: conflict.relativePath,
          ));
        }
        // 'both' is handled similarly to keepBoth above.
      }
      // Clear pending conflicts.
      state = state.copyWith(pendingConflicts: []);
    }

    // Build file items for progress tracking.
    final fileItems = allActions.map((a) => SyncFileItem(
      relativePath: a.relativePath,
      status: SyncFileStatus.pending,
      fileSize: a.localEntry?.size ?? a.remoteEntry?.size ?? 0,
    )).toList();

    final totalBytes = fileItems.fold<int>(0, (sum, f) => sum + f.fileSize);

    job = _findJob(jobId);
    if (job == null) return;
    job = job.copyWith(
      status: 'syncing',
      fileItems: fileItems,
      totalBytes: totalBytes,
      transferredBytes: 0,
      syncedCount: 0,
      failedCount: 0,
      failedFiles: [],
    );
    _updateJob(job);

    int successCount = 0;
    int transferredBytes = 0;
    final failures = <SyncError>[];
    final localDeviceId = discoveryService?.localDevice.id ?? '';

    // ── Resume: load checkpoint ──
    final biCheckpoint =
        await SyncManifestStore.instance.loadCheckpoint('bi_$jobId');
    final biStartIndex =
        (biCheckpoint >= 0 && biCheckpoint < allActions.length)
            ? biCheckpoint + 1
            : 0;
    if (biStartIndex > 0) {
      _log.info(
        'Resuming bidirectional sync from index $biStartIndex '
        '(${allActions.length} total)',
      );
      // Mark skipped items as completed.
      final resumeItems = List<SyncFileItem>.from(job.fileItems);
      for (int s = 0; s < biStartIndex; s++) {
        resumeItems[s] = resumeItems[s].copyWith(
          status: SyncFileStatus.completed,
          completedAt: DateTime.now(),
        );
        final sz =
            allActions[s].localEntry?.size ?? allActions[s].remoteEntry?.size ?? 0;
        transferredBytes += sz;
        successCount++;
      }
      _updateJob(job.copyWith(
        fileItems: resumeItems,
        syncedCount: successCount,
        transferredBytes: transferredBytes,
      ));
    }

    for (int i = biStartIndex; i < allActions.length; i++) {
      // Check cancellation.
      if (cancelToken.isCancelled) {
        _log.info('Bidirectional sync cancelled for job $jobId at index $i');
        break;
      }

      job = _findJob(jobId);
      if (job == null || job.phase == SyncJobPhase.idle) break;

      // Pause support.
      while (job != null && job.phase == SyncJobPhase.paused) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        job = _findJob(jobId);
      }
      if (job == null || job.phase == SyncJobPhase.idle) break;

      final action = allActions[i];
      final items = List<SyncFileItem>.from(job.fileItems);
      items[i] = items[i].copyWith(status: SyncFileStatus.syncing);
      _updateJob(job.copyWith(fileItems: items));

      String? error;

      switch (action.type) {
        case SyncActionType.sendToRemote:
          final filePath = p.join(
            job.sourceDirectory,
            action.relativePath.replaceAll('/', p.separator),
          );
          error = await sender.sendFile(
            targetDevice, filePath, job.sourceDirectory,
            jobId: job.id, jobName: job.name,
            cancel: cancelToken,
          );
          break;

        case SyncActionType.pullFromRemote:
          error = await sender.pullFile(
            targetDevice,
            relativePath: action.relativePath,
            localBasePath: job.sourceDirectory,
            senderName: localName,
            basePath: job.remoteBaseDir,
            jobId: job.id,
            jobName: job.name,
            cancel: cancelToken,
          );
          break;

        case SyncActionType.deleteLocal:
          try {
            final filePath = p.join(
              job.sourceDirectory,
              action.relativePath.replaceAll('/', p.separator),
            );
            final file = File(filePath);
            if (await file.exists()) await file.delete();
          } catch (e) {
            error = 'Local delete failed: $e';
          }
          break;

        case SyncActionType.deleteRemote:
          final ok = await sender.sendDeleteBidirectional(
            targetDevice,
            relativePath: action.relativePath,
            senderName: localName,
            senderDeviceId: localDeviceId,
            basePath: job.remoteBaseDir,
            jobId: job.id,
            jobName: job.name,
          );
          if (!ok) error = 'Remote delete failed';
          break;

        case SyncActionType.conflict:
          // Should have been resolved above; skip.
          break;
      }

      final fileSize = action.localEntry?.size ?? action.remoteEntry?.size ?? 0;
      transferredBytes += fileSize;

      job = _findJob(jobId);
      if (job == null) break;

      if (error == null) {
        successCount++;
        final doneItems = List<SyncFileItem>.from(job.fileItems);
        doneItems[i] = doneItems[i].copyWith(
          status: SyncFileStatus.completed,
          completedAt: DateTime.now(),
        );
        _updateJob(job.copyWith(
          fileItems: doneItems,
          syncedCount: successCount,
          transferredBytes: transferredBytes,
        ));
        // Save checkpoint after successful file.
        await SyncManifestStore.instance.saveCheckpoint('bi_$jobId', i);
      } else {
        failures.add(SyncError(
          filePath: action.relativePath,
          error: error,
          timestamp: DateTime.now(),
        ));
        final failItems = List<SyncFileItem>.from(job.fileItems);
        failItems[i] = failItems[i].copyWith(
          status: SyncFileStatus.failed,
          error: error,
        );
        _updateJob(job.copyWith(
          fileItems: failItems,
          failedCount: failures.length,
          transferredBytes: transferredBytes,
        ));
      }
    }

    // Clear bidirectional checkpoint on completion.
    await SyncManifestStore.instance.deleteCheckpoint('bi_$jobId');

    // ── 7. Save manifests for next sync ──
    // Re-scan local after sync (files may have changed).
    job = _findJob(jobId);
    if (job != null) {
      final newLocalManifest = await _buildLocalManifest(job);
      if (newLocalManifest != null) {
        await store.saveLocalManifest(jobId, newLocalManifest);
      }
      await store.saveRemoteManifest(jobId, remoteManifest);

      _updateJob(job.copyWith(
        phase: SyncJobPhase.watching,
        lastSyncTime: DateTime.now(),
        status: 'syncCompleted',
        syncedCount: successCount,
        failedCount: failures.length,
        failedFiles: failures,
      ));
      _saveJobs();

      _log.info(
        'Bidirectional sync "$jobId": $successCount synced, '
        '${failures.length} failed',
      );

      onSyncBatchCompleted?.call(
        job.name, successCount, job.targetDeviceName,
      );
    }
  }

  /// Scans the local source directory and builds a [SyncManifest].
  ///
  /// Uses async I/O to avoid blocking the UI / event-loop.
  Future<SyncManifest?> _buildLocalManifest(SyncJob job) async {
    try {
      final dir = Directory(job.sourceDirectory);
      if (!await dir.exists()) return null;

      final discoveryService =
          ref.read(discoveryServiceProvider).valueOrNull;
      final deviceId = discoveryService?.localDevice.id ?? '';

      // Scan in a background isolate with hash computation.
      final result = await scanDirectoryInIsolate(ScanParams(
        dirPath: job.sourceDirectory,
        includePatterns: job.includePatterns,
        excludePatterns: job.excludePatterns,
        hashThresholdBytes: 50 * 1024 * 1024, // 50 MB
      ));

      return SyncManifest(
        deviceId: deviceId,
        basePath: job.sourceDirectory,
        createdAt: DateTime.now().toUtc(),
        entries: result.entries,
      );
    } catch (e) {
      _log.error('Failed to build local manifest for job ${job.id}: $e',
          error: e);
      return null;
    }
  }

  /// Resolves a pending conflict by user choice.
  ///
  /// [resolution] should be `'local'`, `'remote'`, or `'both'`.
  void resolveConflict(String relativePath, String resolution) {
    final conflicts = state.pendingConflicts.map((c) {
      if (c.relativePath == relativePath) {
        return c.copyWith(resolution: resolution);
      }
      return c;
    }).toList();
    state = state.copyWith(pendingConflicts: conflicts);
  }

  /// Resolves all pending conflicts with the same resolution.
  void resolveAllConflicts(String resolution) {
    final conflicts = state.pendingConflicts.map((c) {
      if (!c.isResolved) return c.copyWith(resolution: resolution);
      return c;
    }).toList();
    state = state.copyWith(pendingConflicts: conflicts);
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Internal: watcher per job
  // ═══════════════════════════════════════════════════════════════════════════

  void _startWatcher(String jobId, String directory) {
    _watchers[jobId]?.cancel();
    try {
      final watcher = DirectoryWatcher(directory);
      _watchers[jobId] = watcher.events.listen(
        (event) => _handleFileEvent(jobId, event),
        onError: (e) {
          _log.error('Watcher error for job $jobId: $e', error: e);
        },
      );
      _log.info('Started watcher for job $jobId');

      // Mark this job as running so it auto-resumes on next app start.
      final job = _findJob(jobId);
      if (job != null && !job.wasRunning) {
        _updateJob(job.copyWith(wasRunning: true));
        _saveJobs();
      }

      // Keep the app alive while watching (Android foreground service).
      final locale = ref.read(settingsProvider).locale;
      final watchCount = state.jobs.where((j) => j.phase == SyncJobPhase.watching).length;
      BackgroundTransferService.instance.onSyncWatchStarted(
        title: AppLocalizations.get('notifSyncActive', locale),
        text: AppLocalizations.get('notifFoldersWatching', locale)
            .replaceAll('{count}', watchCount.toString()),
      );
    } catch (e) {
      _log.error('Failed to start watcher for job $jobId: $e', error: e);
    }
  }

  void _handleFileEvent(String jobId, WatchEvent event) {
    if (event.type == ChangeType.REMOVE) {
      _handleDeleteEvent(jobId, event.path);
      return;
    }

    // Use async directory check to avoid blocking the UI event-loop.
    FileSystemEntity.isDirectory(event.path).then((isDir) {
      if (isDir) return;
      _handleFileEventAsync(jobId, event);
    }).catchError((_) {
      // Entity may no longer exist — skip.
    });
  }

  void _handleFileEventAsync(String jobId, WatchEvent event) {

    _log.debug('Job $jobId: file changed ${event.path}');

    final pending = _pendingFiles.putIfAbsent(jobId, () => <String>{});
    pending.add(event.path);
    _debounceTimers[jobId]?.cancel();
    _debounceTimers[jobId] =
        Timer(const Duration(seconds: 2), () => _processJobFiles(jobId, _cancelTokens[jobId]));

    // Transition watching → syncing.
    final job = _findJob(jobId);
    if (job != null && job.phase == SyncJobPhase.watching) {
      _updateJob(job.copyWith(phase: SyncJobPhase.syncing, status: 'syncChangeDetected'));
    }
  }

  Future<void> _handleDeleteEvent(String jobId, String path) async {
    final job = _findJob(jobId);
    if (job == null) return;

    // Skip if mirror deletions is disabled for this job.
    if (!job.mirrorDeletions) return;

    final relPath = p.relative(path, from: job.sourceDirectory)
        .replaceAll(r'\', '/');

    // Skip if file doesn't match filters.
    if (!_matchesFilters(relPath, job)) return;

    final targetDevice = _resolveDevice(job);
    if (targetDevice == null) return;

    _log.info('Job $jobId: file deleted $path');
    final sender = ref.read(syncSenderProvider);
    await sender.sendDelete(
      targetDevice, path, job.sourceDirectory,
      jobId: job.id, jobName: job.name,
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Internal: filter matching
  // ═══════════════════════════════════════════════════════════════════════════

  /// Returns `true` if [relativePath] passes the job's include/exclude filters.
  bool _matchesFilters(String relativePath, SyncJob job) {
    // Fast-reject: skip files inside always-excluded directories.
    final firstSegment = relativePath.split('/').first;
    if (alwaysExcludeDirs.contains(firstSegment)) return false;

    // If include patterns are set, the file must match at least one.
    if (job.includePatterns.isNotEmpty) {
      final matches = job.includePatterns.any((pattern) =>
          _globMatch(relativePath, pattern));
      if (!matches) return false;
    }
    // If exclude patterns are set, the file must not match any.
    if (job.excludePatterns.isNotEmpty) {
      final excluded = job.excludePatterns.any((pattern) =>
          _globMatch(relativePath, pattern));
      if (excluded) return false;
    }
    return true;
  }

  /// Simple glob matching supporting `*` (any segment), `**` (recursive), and
  /// `*.ext` (extension). This covers the most common use cases without pulling
  /// in a full glob dependency.
  static bool _globMatch(String path, String pattern) {
    // Normalise separators.
    final normPath = path.replaceAll(r'\', '/').toLowerCase();
    final normPattern = pattern.replaceAll(r'\', '/').toLowerCase().trim();

    // Extension match: "*.jpg"
    if (normPattern.startsWith('*.') && !normPattern.contains('/')) {
      return normPath.endsWith(normPattern.substring(1));
    }
    // Recursive directory match: "node_modules/**" or "**/node_modules"
    if (normPattern.contains('**')) {
      // "dir/**" means anything under dir.
      final parts = normPattern.split('**');
      if (parts.length == 2) {
        final prefix = parts[0].replaceAll(RegExp(r'/$'), '');
        final suffix = parts[1].replaceAll(RegExp(r'^/'), '');
        if (prefix.isNotEmpty && suffix.isEmpty) {
          return normPath.startsWith('$prefix/') || normPath == prefix;
        }
        if (prefix.isEmpty && suffix.isNotEmpty) {
          return normPath.endsWith(suffix) || normPath.contains('/$suffix');
        }
      }
    }
    // Exact name match (e.g. ".DS_Store", "Thumbs.db").
    if (!normPattern.contains('/') && !normPattern.contains('*')) {
      final fileName = normPath.split('/').last;
      return fileName == normPattern;
    }
    // Fallback: simple contains.
    return normPath.contains(normPattern);
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Internal: process pending files for a job
  // ═══════════════════════════════════════════════════════════════════════════

  Future<void> _processJobFiles(String jobId, [CancellationToken? cancel]) async {
    final pending = _pendingFiles[jobId];
    _log.info('_processJobFiles("$jobId"): pending=${pending?.length ?? 0}');
    if (pending == null || pending.isEmpty) {
      _log.info('_processJobFiles("$jobId"): no pending files, returning');
      return;
    }

    var job = _findJob(jobId);
    if (job == null) {
      _log.warning('_processJobFiles("$jobId"): job not found!');
      return;
    }

    final targetDevice = _resolveDevice(job);
    if (targetDevice == null) {
      _updateJob(job.copyWith(phase: SyncJobPhase.error, status: 'syncCannotReach'));
      return;
    }

    final filesToSync = List<String>.from(pending);
    pending.clear();

    final sender = ref.read(syncSenderProvider);

    // Build file items, applying include/exclude filters.
    final items = <SyncFileItem>[];
    final filteredFiles = <String>[];
    int totalBytes = 0;
    int yieldCounter = 0;
    final sourceForFilter = job.sourceDirectory;
    for (final filePath in filesToSync) {
      final file = File(filePath);
      final relPath = p.relative(filePath, from: sourceForFilter)
          .replaceAll(r'\', '/');

      // Apply filters.
      if (!_matchesFilters(relPath, job)) continue;

      final size = await file.exists() ? await file.length() : 0;
      totalBytes += size;
      filteredFiles.add(filePath);
      items.add(SyncFileItem(
        relativePath: relPath,
        status: SyncFileStatus.pending,
        fileSize: size,
      ));

      // Yield periodically to keep UI responsive.
      if (++yieldCounter % 50 == 0) {
        await Future<void>.delayed(Duration.zero);
        final current = _findJob(jobId);
        if (current == null || current.phase == SyncJobPhase.idle) return;
      }
    }
    // Replace with filtered list.
    filesToSync
      ..clear()
      ..addAll(filteredFiles);

    // Re-fetch after loop; bail if gone.
    job = _findJob(jobId);
    if (job == null) return;

    job = job.copyWith(
      phase: SyncJobPhase.syncing,
      status: 'syncing',
      fileItems: items,
      failedFiles: [],
      failedCount: 0,
      syncedCount: 0,
      totalBytes: totalBytes,
      transferredBytes: 0,
      syncStartTime: DateTime.now(),
    );
    _updateJob(job);

    int successCount = 0;
    int transferredBytes = 0;
    final failures = <SyncError>[];

    // Keep a mutable local copy of file items so we don't need to copy the
    // entire list from the (immutable) state on every iteration.
    final localItems = List<SyncFileItem>.from(items);

    // Throttle UI updates: flush progress every N files or every 2 seconds,
    // whichever comes first. This prevents O(n²) state rebuilds that freeze
    // the UI when syncing thousands of files.
    const uiFlushInterval = 10;
    var lastUiFlush = DateTime.now();
    bool uiDirty = false;

    void flushUi({bool force = false}) {
      if (!uiDirty && !force) return;
      final now = DateTime.now();
      if (!force &&
          (successCount + failures.length) % uiFlushInterval != 0 &&
          now.difference(lastUiFlush).inSeconds < 2) {
        return;
      }
      final j = _findJob(jobId);
      if (j == null) return;
      _updateJob(j.copyWith(
        fileItems: List<SyncFileItem>.unmodifiable(localItems),
        syncedCount: successCount,
        failedCount: failures.length,
        transferredBytes: transferredBytes,
      ));
      lastUiFlush = now;
      uiDirty = false;
    }

    // Load checkpoint for resume-after-crash.
    final checkpoint =
        await SyncManifestStore.instance.loadCheckpoint(jobId);
    final startIndex =
        (checkpoint >= 0 && checkpoint < filesToSync.length)
            ? checkpoint + 1
            : 0;

    for (int i = startIndex; i < filesToSync.length; i++) {
      // Check cancellation.
      if (cancel != null && cancel.isCancelled) {
        _log.info('One-way sync cancelled for job $jobId at index $i');
        break;
      }

      // Re-read job (state may have been modified by pause/stop/skip).
      job = _findJob(jobId);
      if (job == null || job.phase == SyncJobPhase.idle) break;

      // Pause loop.
      while (job != null && job.phase == SyncJobPhase.paused) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        job = _findJob(jobId);
      }
      if (job == null || job.phase == SyncJobPhase.idle) break;

      // Skipped?
      if (localItems.length > i &&
          localItems[i].status == SyncFileStatus.skipped) {
        continue;
      }

      final filePath = filesToSync[i];
      final file = File(filePath);
      final fileSize = await file.exists() ? await file.length() : 0;
      final relPath = items[i].relativePath;

      // Mark as syncing (local only — no state push).
      localItems[i] = localItems[i].copyWith(status: SyncFileStatus.syncing);

      // ── Periodic ping check ──
      if (i > 0 && i % 50 == 0) {
        final lastPing = _lastPingTimes[jobId];
        if (lastPing == null ||
            DateTime.now().difference(lastPing).inMinutes >= 5) {
          final reachable = await sender.pingTarget(targetDevice);
          if (reachable) {
            _lastPingTimes[jobId] = DateTime.now();
          } else {
            flushUi(force: true);
            final reconnected = await _waitForReconnection(jobId, sender, targetDevice);
            if (!reconnected) {
              final j = _findJob(jobId);
              if (j != null) {
                _updateJob(j.copyWith(
                    phase: SyncJobPhase.error, status: 'syncCannotReach'));
              }
              return;
            }
          }
        }
      }

      // ── Send file with retries ──
      String? lastError;
      bool success = false;

      for (int attempt = 1; attempt <= _maxRetries + 1; attempt++) {
        lastError = await sender.sendFile(
          targetDevice,
          filePath,
          job.sourceDirectory,
          isPhotoMode: job.isPhotoMode,
          dateSubfolderFormat: job.dateSubfolderFormat,
          convertHeicToJpg: job.convertHeicToJpg,
          jobId: job.id,
          jobName: job.name,
          cancel: cancel,
        );
        success = lastError == null;
        if (success) break;
        if (attempt <= _maxRetries) {
          await Future<void>.delayed(Duration(seconds: attempt));
        }
      }

      transferredBytes += fileSize;

      if (success) {
        successCount++;
        localItems[i] = localItems[i].copyWith(
          status: SyncFileStatus.completed,
          completedAt: DateTime.now(),
        );
        // Save checkpoint for resume-after-crash.
        await SyncManifestStore.instance.saveCheckpoint(jobId, i);
      } else {
        failures.add(SyncError(
          filePath: relPath,
          error: lastError ?? 'Unknown error',
          timestamp: DateTime.now(),
        ));
        localItems[i] = localItems[i].copyWith(
          status: SyncFileStatus.failed,
          error: lastError,
        );
      }

      uiDirty = true;
      flushUi();

      // Yield every few files to prevent event-loop starvation.
      if (i % 5 == 0) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    // Final flush to ensure UI reflects the last files.
    flushUi(force: true);

    // ── Batch complete ──
    job = _findJob(jobId);
    if (job == null) return;

    _log.info(
      'Job "$jobId": synced $successCount/${filesToSync.length} files '
      '(${failures.length} failed)',
    );

    _updateJob(job.copyWith(
      phase: SyncJobPhase.watching,
      lastSyncTime: DateTime.now(),
      status: failures.isEmpty ? 'syncCompleted' : 'syncCompleted',
      syncedCount: successCount,
      failedCount: failures.length,
      failedFiles: failures,
    ));
    _saveJobs();

    // Clear checkpoint on successful completion.
    await SyncManifestStore.instance.deleteCheckpoint(jobId);

    // Persist the manifest snapshot so next sync only transfers changes.
    final completedManifest = _pendingManifests.remove(jobId);
    if (completedManifest != null) {
      try {
        final store = SyncManifestStore.instance;
        await store.saveLocalManifest(jobId, completedManifest);
        _log.info('Job "$jobId": manifest saved (${completedManifest.entries.length} entries)');
      } catch (e) {
        _log.warning('Job "$jobId": failed to save manifest: $e');
      }
    }

    // Fire summary notification.
    onSyncBatchCompleted?.call(
      job.name, successCount, job.targetDeviceName,
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Internal: reconnection
  // ═══════════════════════════════════════════════════════════════════════════

  Future<bool> _waitForReconnection(
    String jobId, SyncSender sender, Device target,
  ) async {
    final job = _findJob(jobId);
    if (job != null) {
      _updateJob(job.copyWith(status: 'syncReconnecting'));
    }

    const delays = [30, 60, 120]; // seconds
    for (final delay in delays) {
      await Future<void>.delayed(Duration(seconds: delay));
      if (await sender.pingTarget(target)) {
        _lastPingTimes[jobId] = DateTime.now();
        final j = _findJob(jobId);
        if (j != null) _updateJob(j.copyWith(status: 'syncing'));
        return true;
      }
    }
    return false;
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Internal: schedule
  // ═══════════════════════════════════════════════════════════════════════════

  void _startScheduleTimer(SyncJob job) {
    _scheduleTimers[job.id]?.cancel();
    final schedule = job.schedule;
    if (schedule == null || !schedule.enabled) return;

    if (schedule.type == ScheduleType.interval && schedule.interval != null) {
      _scheduleTimers[job.id] = Timer.periodic(schedule.interval!, (_) {
        _tryScheduledSync(job.id);
      });
    } else {
      _scheduleTimers[job.id] = Timer.periodic(const Duration(minutes: 1), (_) {
        _checkTimeBasedSchedule(job.id, schedule);
      });
    }
  }

  void _checkTimeBasedSchedule(String jobId, SyncSchedule schedule) {
    if (schedule.time == null) return;
    final now = DateTime.now();
    final currentTime = TimeOfDay.fromDateTime(now);

    if (currentTime.hour != schedule.time!.hour ||
        currentTime.minute != schedule.time!.minute) {
      return;
    }

    if (schedule.type == ScheduleType.weekly && schedule.weekDays.isNotEmpty) {
      if (!schedule.weekDays.contains(now.weekday)) return;
    }

    _tryScheduledSync(jobId);
  }

  Future<void> _tryScheduledSync(String jobId) async {
    final job = _findJob(jobId);
    if (job == null) return;
    if (job.phase == SyncJobPhase.syncing) return; // Already running.

    final dir = Directory(job.sourceDirectory);
    if (!await dir.exists()) {
      _log.warning('Scheduled sync skipped for "$jobId": source dir missing');
      return;
    }

    _log.info('Starting scheduled sync for job "${job.name}"');
    startJob(jobId);
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Helpers
  // ═══════════════════════════════════════════════════════════════════════════

  SyncJob? _findJob(String jobId) {
    final idx = state.jobs.indexWhere((j) => j.id == jobId);
    return idx >= 0 ? state.jobs[idx] : null;
  }

  void _updateJob(SyncJob job) {
    state = state.updateJob(job);
  }

  /// Resolves a [Device] instance for the job's target from the discovery service,
  /// falling back to cached IP from the job itself.
  Device? _resolveDevice(SyncJob job) {
    try {
      final deviceList = ref.read(devicesProvider).valueOrNull ?? [];
      final match = deviceList.cast<Device>().firstWhere(
        (d) => d.id == job.targetDeviceId,
        orElse: () => Device(
          id: job.targetDeviceId,
          name: job.targetDeviceName,
          ip: job.targetDeviceIp ?? '',
          port: 0,
          platform: 'unknown',
          version: '',
          lastSeen: DateTime.now(),
        ),
      );
      if (match.ip.isEmpty) return null;
      return match;
    } catch (_) {
      if (job.targetDeviceIp != null && job.targetDeviceIp!.isNotEmpty) {
        return Device(
          id: job.targetDeviceId,
          name: job.targetDeviceName,
          ip: job.targetDeviceIp!,
          port: 0,
          platform: 'unknown',
          version: '',
          lastSeen: DateTime.now(),
        );
      }
      return null;
    }
  }

  void _stopJobInternal(String jobId) {
    // Cancel any in-flight transfers for this job.
    _cancelTokens[jobId]?.cancel();
    _cancelTokens.remove(jobId);

    final hadWatcher = _watchers.containsKey(jobId);
    _watchers[jobId]?.cancel();
    _watchers.remove(jobId);
    _debounceTimers[jobId]?.cancel();
    _debounceTimers.remove(jobId);
    _scheduleTimers[jobId]?.cancel();
    _scheduleTimers.remove(jobId);
    _pendingFiles.remove(jobId);
    _lastPingTimes.remove(jobId);
    _pendingManifests.remove(jobId);

    // Release foreground service if no more watchers active.
    if (hadWatcher) {
      BackgroundTransferService.instance.onSyncWatchStopped();
    }
  }

  @override
  void dispose() {
    for (final sub in _watchers.values) {
      sub.cancel();
    }
    for (final timer in _debounceTimers.values) {
      timer?.cancel();
    }
    for (final timer in _scheduleTimers.values) {
      timer?.cancel();
    }
    super.dispose();
  }
}
