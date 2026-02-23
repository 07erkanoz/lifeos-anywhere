import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:watcher/watcher.dart';

import 'package:anyware/core/logger.dart';
import 'package:anyware/features/server_sync/data/sftp_transport.dart';
import 'package:anyware/features/server_sync/domain/server_sync_job.dart';
import 'package:anyware/features/server_sync/domain/server_sync_state.dart';
import 'package:anyware/features/server_sync/domain/sftp_server_config.dart';
import 'package:anyware/features/sync/data/sync_diff_engine.dart';
import 'package:anyware/features/sync/data/sync_filter_utils.dart';
import 'package:anyware/features/sync/data/sync_manifest_store.dart';
import 'package:anyware/features/sync/domain/sync_manifest.dart';
import 'package:anyware/features/sync/domain/sync_state.dart';

final _log = AppLogger('ServerSyncService');
const _uuid = Uuid();

// ── Providers ────────────────────────────────────────────────────────────────

final sftpTransportProvider = Provider((_) => SftpTransport());

final serverSyncServiceProvider =
    StateNotifierProvider<ServerSyncService, ServerSyncState>((ref) {
  return ServerSyncService(ref);
});

// ── Service ──────────────────────────────────────────────────────────────────

class ServerSyncService extends StateNotifier<ServerSyncState> {
  ServerSyncService(this.ref) : super(const ServerSyncState()) {
    _init();
  }

  final Ref ref;

  static const _prefServers = 'sftp_servers_v1';
  static const _prefJobs = 'sftp_sync_jobs_v1';

  SftpTransport get _transport => ref.read(sftpTransportProvider);

  // Per-job watchers (live watch mode).
  final Map<String, StreamSubscription> _watchers = {};
  final Map<String, Timer> _debouncers = {};
  final Map<String, Set<String>> _pendingFiles = {};

  // Per-job schedule timers.
  final Map<String, Timer> _scheduleTimers = {};

  // Active SFTP sessions for live-watch (kept open).
  final Map<String, SftpSession> _liveSessions = {};

  // ═══════════════════════════════════════════════════════════════════════════
  // Initialisation & persistence
  // ═══════════════════════════════════════════════════════════════════════════

  Future<void> _init() async {
    await _loadServers();
    await _loadJobs();
    // Auto-resume jobs that were running before the app closed.
    Future.delayed(const Duration(seconds: 4), _autoResumeJobs);
  }

  Future<SharedPreferences> get _prefs => SharedPreferences.getInstance();

  Future<void> _loadServers() async {
    try {
      final prefs = await _prefs;
      final raw = prefs.getString(_prefServers);
      if (raw != null) {
        final list = (jsonDecode(raw) as List<dynamic>)
            .map((e) =>
                SftpServerConfig.fromJson(e as Map<String, dynamic>))
            .toList();
        state = state.copyWith(servers: list);
      }
    } catch (e) {
      _log.error('Failed to load servers: $e', error: e);
    }
  }

  Future<void> _saveServers() async {
    final prefs = await _prefs;
    final json = state.servers.map((s) => s.toJson()).toList();
    await prefs.setString(_prefServers, jsonEncode(json));
  }

  Future<void> _loadJobs() async {
    try {
      final prefs = await _prefs;
      final raw = prefs.getString(_prefJobs);
      if (raw != null) {
        final list = (jsonDecode(raw) as List<dynamic>)
            .map((e) =>
                ServerSyncJob.fromJson(e as Map<String, dynamic>))
            .toList();
        // Reset active phases to idle on load.
        final resetList = list.map((j) {
          if (j.phase == SyncJobPhase.syncing ||
              j.phase == SyncJobPhase.watching) {
            return j.copyWith(phase: SyncJobPhase.idle);
          }
          return j;
        }).toList();
        state = state.copyWith(jobs: resetList);
      }
    } catch (e) {
      _log.error('Failed to load jobs: $e', error: e);
    }
  }

  Future<void> _saveJobs() async {
    final prefs = await _prefs;
    final json = state.jobs.map((j) => j.toJson()).toList();
    await prefs.setString(_prefJobs, jsonEncode(json));
  }

  void _autoResumeJobs() {
    for (final job in state.jobs) {
      if (job.wasRunning) {
        _log.info('Auto-resuming server sync job: ${job.name}');
        startJob(job.id);
      }
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Server CRUD
  // ═══════════════════════════════════════════════════════════════════════════

  Future<String> addServer(SftpServerConfig server) async {
    state = state.copyWith(servers: [...state.servers, server]);
    await _saveServers();
    return server.id;
  }

  Future<void> updateServer(SftpServerConfig server) async {
    final servers = state.servers.map((s) {
      return s.id == server.id ? server : s;
    }).toList();
    state = state.copyWith(servers: servers);
    await _saveServers();
  }

  Future<void> deleteServer(String serverId) async {
    // Stop and remove all jobs for this server.
    final jobsToRemove =
        state.jobs.where((j) => j.serverId == serverId).toList();
    for (final job in jobsToRemove) {
      stopJob(job.id);
      await SyncManifestStore.instance.deleteManifests('sftp_${job.id}');
    }
    final remainingJobs =
        state.jobs.where((j) => j.serverId != serverId).toList();
    final remainingServers =
        state.servers.where((s) => s.id != serverId).toList();
    state = state.copyWith(servers: remainingServers, jobs: remainingJobs);
    await _saveServers();
    await _saveJobs();
  }

  Future<bool> testServer(String serverId) async {
    final server = state.serverById(serverId);
    if (server == null) return false;
    final ok = await _transport.testConnection(server);
    if (ok) {
      await updateServer(
          server.copyWith(lastConnectedAt: DateTime.now()));
    }
    return ok;
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Job CRUD
  // ═══════════════════════════════════════════════════════════════════════════

  Future<String> createJob({
    required String name,
    required String sourceDirectory,
    required String serverId,
    String remoteSubPath = '',
    SyncDirection syncDirection = SyncDirection.oneWay,
    ConflictStrategy conflictStrategy = ConflictStrategy.newerWins,
    List<String> includePatterns = const [],
    List<String> excludePatterns = const [],
    bool mirrorDeletions = true,
    bool liveWatch = false,
  }) async {
    final server = state.serverById(serverId);
    final job = ServerSyncJob(
      id: _uuid.v4(),
      name: name,
      sourceDirectory: sourceDirectory,
      serverId: serverId,
      serverName: server?.name ?? '',
      remoteSubPath: remoteSubPath,
      createdAt: DateTime.now(),
      syncDirection: syncDirection,
      conflictStrategy: conflictStrategy,
      includePatterns: includePatterns,
      excludePatterns: excludePatterns,
      mirrorDeletions: mirrorDeletions,
      liveWatch: liveWatch,
    );
    state = state.copyWith(jobs: [...state.jobs, job]);
    await _saveJobs();
    return job.id;
  }

  Future<void> deleteJob(String jobId) async {
    stopJob(jobId);
    await SyncManifestStore.instance.deleteManifests('sftp_$jobId');
    final remaining = state.jobs.where((j) => j.id != jobId).toList();
    state = state.copyWith(jobs: remaining);
    await _saveJobs();
  }

  void selectJob(String? jobId) {
    state = state.copyWith(
      activeJobId: jobId,
      clearActiveJobId: jobId == null,
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Sync control
  // ═══════════════════════════════════════════════════════════════════════════

  Future<void> startJob(String jobId) async {
    var job = _findJob(jobId);
    if (job == null || job.isActive) return;

    final server = state.serverById(job.serverId);
    if (server == null) {
      _updateJob(job.copyWith(
        phase: SyncJobPhase.error,
        status: 'Server not found',
      ));
      return;
    }

    // Validate source directory.
    if (!await Directory(job.sourceDirectory).exists()) {
      _updateJob(job.copyWith(
        phase: SyncJobPhase.error,
        status: 'Source directory not found',
      ));
      return;
    }

    _updateJob(job.copyWith(
      phase: SyncJobPhase.syncing,
      status: 'serverSyncConnecting',
      wasRunning: true,
      syncStartTime: DateTime.now(),
      fileItems: [],
      totalBytes: 0,
      transferredBytes: 0,
      syncedCount: 0,
      failedCount: 0,
      failedFiles: [],
    ));
    _saveJobs();

    // Run the actual sync.
    try {
      await _executeSyncJob(jobId, server);
    } catch (e) {
      _log.error('Sync job $jobId failed: $e', error: e);
      job = _findJob(jobId);
      if (job != null && job.phase != SyncJobPhase.idle) {
        _updateJob(job.copyWith(
          phase: SyncJobPhase.error,
          status: e.toString(),
        ));
      }
    }

    // After sync, start live watcher if enabled.
    job = _findJob(jobId);
    if (job != null &&
        job.liveWatch &&
        job.phase != SyncJobPhase.idle &&
        job.phase != SyncJobPhase.error) {
      _startLiveWatch(job, server);
    }

    // Start schedule timer if configured.
    job = _findJob(jobId);
    if (job?.schedule != null && (job!.schedule!.enabled)) {
      _startScheduleTimer(job);
    }
  }

  void stopJob(String jobId) {
    _watchers[jobId]?.cancel();
    _watchers.remove(jobId);
    _debouncers[jobId]?.cancel();
    _debouncers.remove(jobId);
    _pendingFiles.remove(jobId);
    _scheduleTimers[jobId]?.cancel();
    _scheduleTimers.remove(jobId);
    _liveSessions[jobId]?.close();
    _liveSessions.remove(jobId);

    final job = _findJob(jobId);
    if (job != null) {
      _updateJob(job.copyWith(
        phase: SyncJobPhase.idle,
        wasRunning: false,
      ));
      _saveJobs();
    }
  }

  void pauseJob(String jobId) {
    final job = _findJob(jobId);
    if (job != null && job.isActive) {
      _updateJob(job.copyWith(phase: SyncJobPhase.paused));
    }
  }

  void resumeJob(String jobId) {
    final job = _findJob(jobId);
    if (job != null && job.phase == SyncJobPhase.paused) {
      _updateJob(job.copyWith(phase: SyncJobPhase.syncing));
    }
  }

  void stopAll() {
    for (final job in state.jobs) {
      if (job.isActive || job.phase == SyncJobPhase.paused) {
        stopJob(job.id);
      }
    }
    // Close any leftover SFTP sessions not tied to an active job.
    for (final entry in _liveSessions.entries.toList()) {
      try {
        entry.value.close();
      } catch (_) {}
    }
    _liveSessions.clear();
    // Cancel any remaining timers.
    for (final t in _scheduleTimers.values) {
      t.cancel();
    }
    _scheduleTimers.clear();
    for (final t in _debouncers.values) {
      t.cancel();
    }
    _debouncers.clear();
    for (final w in _watchers.values) {
      w.cancel();
    }
    _watchers.clear();
    _pendingFiles.clear();
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Sync execution
  // ═══════════════════════════════════════════════════════════════════════════

  Future<void> _executeSyncJob(
    String jobId,
    SftpServerConfig server,
  ) async {
    var job = _findJob(jobId);
    if (job == null) return;

    // ── 1. Connect ──
    _updateJob(job.copyWith(status: 'serverSyncConnecting'));
    SftpSession? session;
    try {
      session = await _transport.connect(server);
    } catch (e) {
      _updateJob(job.copyWith(
        phase: SyncJobPhase.error,
        status: 'serverSyncDisconnected',
      ));
      return;
    }

    try {
      // ── 2. Build local manifest ──
      job = _findJob(jobId);
      if (job == null || job.phase == SyncJobPhase.idle) return;
      _updateJob(job.copyWith(status: 'syncBuildingManifest'));

      final localManifest = await _buildLocalManifest(job);

      // ── 3. Build remote manifest ──
      job = _findJob(jobId);
      if (job == null || job.phase == SyncJobPhase.idle) return;
      _updateJob(job.copyWith(status: 'serverSyncScanning'));

      final remotePath = _remotePath(server, job);

      // Ensure remote directory exists.
      await _transport.ensureRemoteDir(session.sftp, remotePath);

      final remoteManifest = await _transport.buildRemoteManifest(
        session.sftp,
        remotePath,
        server.id,
      );

      // ── 4. Compute diff ──
      final store = SyncManifestStore.instance;
      final prevLocal = await store.loadLocalManifest('sftp_$jobId');
      final prevRemote = await store.loadRemoteManifest('sftp_$jobId');

      _updateJob(job.copyWith(status: 'syncComputingDiff'));
      final plan = computeSyncPlan(
        local: localManifest,
        remote: remoteManifest,
        previousLocal: prevLocal,
        previousRemote: prevRemote,
        conflictStrategy: job.conflictStrategy,
        mirrorDeletions: job.mirrorDeletions,
      );

      _log.info(
          'Job "$jobId" plan: ${plan.sends.length} send, '
          '${plan.pulls.length} pull, '
          '${plan.localDeletes.length} localDel, '
          '${plan.remoteDeletes.length} remoteDel');

      if (plan.isEmpty) {
        job = _findJob(jobId);
        if (job != null) {
          _updateJob(job.copyWith(
            phase: job.liveWatch
                ? SyncJobPhase.watching
                : SyncJobPhase.idle,
            status: 'syncCompleted',
            lastSyncTime: DateTime.now(),
            wasRunning: job.liveWatch,
          ));
          await store.saveLocalManifest('sftp_$jobId', localManifest);
          await store.saveRemoteManifest('sftp_$jobId', remoteManifest);
          _saveJobs();
        }
        return;
      }

      // ── 5. Build action list ──
      final allActions = <SyncAction>[
        ...plan.sends,
        ...plan.pulls,
        if (job.mirrorDeletions) ...plan.localDeletes,
        if (job.mirrorDeletions) ...plan.remoteDeletes,
      ];

      // Handle conflicts for keepBoth.
      if (plan.hasConflicts &&
          job.conflictStrategy == ConflictStrategy.keepBoth) {
        for (final conflict in plan.conflicts) {
          allActions.add(SyncAction(
            type: SyncActionType.sendToRemote,
            relativePath: conflict.relativePath,
            localEntry: conflict.localEntry,
            remoteEntry: conflict.remoteEntry,
          ));
        }
      }

      // newerWins conflicts are already resolved in the plan.

      // Build file items for progress tracking.
      final fileItems = allActions
          .map((a) => SyncFileItem(
                relativePath: a.relativePath,
                status: SyncFileStatus.pending,
                fileSize: a.localEntry?.size ?? a.remoteEntry?.size ?? 0,
              ))
          .toList();

      final totalBytes =
          fileItems.fold<int>(0, (sum, f) => sum + f.fileSize);

      job = _findJob(jobId);
      if (job == null) return;
      _updateJob(job.copyWith(
        status: 'syncing',
        fileItems: fileItems,
        totalBytes: totalBytes,
        transferredBytes: 0,
        syncedCount: 0,
        failedCount: 0,
        failedFiles: [],
      ));

      // ── 6. Execute actions ──
      int successCount = 0;
      int transferred = 0;
      final failures = <SyncError>[];

      for (int i = 0; i < allActions.length; i++) {
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
            final localPath = p.join(
              job.sourceDirectory,
              action.relativePath.replaceAll('/', p.separator),
            );
            final remoteFilePath =
                '$remotePath/${action.relativePath}';
            error = await _transport.uploadFile(
              session.sftp,
              localPath,
              remoteFilePath,
              onProgress: (bytes) {
                // Throttled progress updates.
              },
            );
            break;

          case SyncActionType.pullFromRemote:
            final localPath = p.join(
              job.sourceDirectory,
              action.relativePath.replaceAll('/', p.separator),
            );
            final remoteFilePath =
                '$remotePath/${action.relativePath}';
            error = await _transport.downloadFile(
              session.sftp,
              remoteFilePath,
              localPath,
            );
            break;

          case SyncActionType.deleteLocal:
            try {
              final localPath = p.join(
                job.sourceDirectory,
                action.relativePath.replaceAll('/', p.separator),
              );
              final f = File(localPath);
              if (await f.exists()) await f.delete();
            } catch (e) {
              error = e.toString();
            }
            break;

          case SyncActionType.deleteRemote:
            final remoteFilePath =
                '$remotePath/${action.relativePath}';
            final ok = await _transport.deleteRemoteFile(
                session.sftp, remoteFilePath);
            if (!ok) error = 'Failed to delete remote file';
            break;

          case SyncActionType.conflict:
            // Should have been resolved above.
            break;
        }

        // Update file status.
        job = _findJob(jobId);
        if (job == null) break;
        final updatedItems = List<SyncFileItem>.from(job.fileItems);
        if (error == null) {
          successCount++;
          final fileSize = updatedItems[i].fileSize;
          transferred += fileSize;
          updatedItems[i] = updatedItems[i].copyWith(
            status: SyncFileStatus.completed,
            completedAt: DateTime.now(),
          );
        } else {
          failures.add(SyncError(
            filePath: action.relativePath,
            error: error,
            timestamp: DateTime.now(),
          ));
          updatedItems[i] =
              updatedItems[i].copyWith(status: SyncFileStatus.failed);
        }
        _updateJob(job.copyWith(
          fileItems: updatedItems,
          transferredBytes: transferred,
          syncedCount: successCount,
          failedCount: failures.length,
          failedFiles: failures,
        ));
      }

      // ── 7. Save manifests & finalise ──
      await store.saveLocalManifest('sftp_$jobId', localManifest);
      await store.saveRemoteManifest('sftp_$jobId', remoteManifest);

      job = _findJob(jobId);
      if (job != null && job.phase != SyncJobPhase.idle) {
        _updateJob(job.copyWith(
          phase: job.liveWatch
              ? SyncJobPhase.watching
              : SyncJobPhase.idle,
          status: 'syncCompleted',
          lastSyncTime: DateTime.now(),
          wasRunning: job.liveWatch,
        ));
        _saveJobs();
      }
    } finally {
      session.close();
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Live watch (file system watcher → SFTP push)
  // ═══════════════════════════════════════════════════════════════════════════

  void _startLiveWatch(ServerSyncJob job, SftpServerConfig server) {
    _watchers[job.id]?.cancel();
    final watcher = DirectoryWatcher(job.sourceDirectory);
    _watchers[job.id] = watcher.events.listen((event) {
      _onLocalFileChange(job.id, event, server);
    });
    _log.info('Live watch started for job ${job.name}');
  }

  void _onLocalFileChange(
      String jobId, WatchEvent event, SftpServerConfig server) {
    final job = _findJob(jobId);
    if (job == null || job.phase == SyncJobPhase.idle) return;

    _pendingFiles.putIfAbsent(jobId, () => {});
    _pendingFiles[jobId]!.add(event.path);

    // Debounce: wait 3 seconds for batch.
    _debouncers[jobId]?.cancel();
    _debouncers[jobId] = Timer(const Duration(seconds: 3), () {
      _flushPendingFiles(jobId, server);
    });
  }

  Future<void> _flushPendingFiles(
      String jobId, SftpServerConfig server) async {
    final job = _findJob(jobId);
    if (job == null) return;

    final pending = _pendingFiles[jobId]?.toList() ?? [];
    _pendingFiles[jobId]?.clear();
    if (pending.isEmpty) return;

    _log.info('Live watch: flushing ${pending.length} changed files for ${job.name}');
    _updateJob(job.copyWith(phase: SyncJobPhase.syncing, status: 'syncing'));

    SftpSession? session;
    try {
      // Reuse existing session or create new.
      session = _liveSessions[jobId];
      if (session == null) {
        session = await _transport.connect(server);
        _liveSessions[jobId] = session;
      }

      final remotePath = _remotePath(server, job);

      for (final filePath in pending) {
        final file = File(filePath);
        if (!await file.exists()) continue;

        final relativePath = p
            .relative(filePath, from: job.sourceDirectory)
            .replaceAll(r'\', '/');

        // Check filters.
        if (!matchesSyncFilters(
          relativePath,
          includePatterns: job.includePatterns,
          excludePatterns: job.excludePatterns,
        )) {
          continue;
        }

        final remoteFilePath = '$remotePath/$relativePath';
        final error = await _transport.uploadFile(
            session.sftp, filePath, remoteFilePath);
        if (error != null) {
          _log.warning('Live watch upload failed: $relativePath — $error');
        }
      }

      final updatedJob = _findJob(jobId);
      if (updatedJob != null && updatedJob.phase != SyncJobPhase.idle) {
        _updateJob(updatedJob.copyWith(
          phase: SyncJobPhase.watching,
          status: 'syncWatching',
          lastSyncTime: DateTime.now(),
        ));
      }
    } catch (e) {
      _log.error('Live watch flush error: $e', error: e);
      // Close broken session so next flush reconnects.
      _liveSessions[jobId]?.close();
      _liveSessions.remove(jobId);

      final updatedJob = _findJob(jobId);
      if (updatedJob != null) {
        _updateJob(updatedJob.copyWith(
          phase: SyncJobPhase.error,
          status: 'serverSyncDisconnected',
        ));
      }
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Schedule
  // ═══════════════════════════════════════════════════════════════════════════

  void _startScheduleTimer(ServerSyncJob job) {
    _scheduleTimers[job.id]?.cancel();
    final schedule = job.schedule;
    if (schedule == null || !schedule.enabled) return;

    if (schedule.type == ScheduleType.interval && schedule.interval != null) {
      _scheduleTimers[job.id] = Timer.periodic(schedule.interval!, (_) {
        _tryScheduledSync(job.id);
      });
    } else {
      // Daily / weekly — check every minute.
      _scheduleTimers[job.id] =
          Timer.periodic(const Duration(minutes: 1), (_) {
        _tryScheduledSync(job.id);
      });
    }
  }

  void _tryScheduledSync(String jobId) {
    final job = _findJob(jobId);
    if (job == null || job.phase != SyncJobPhase.idle) return;

    final schedule = job.schedule;
    if (schedule == null || !schedule.enabled) return;

    final now = TimeOfDay.now();

    if (schedule.type == ScheduleType.daily && schedule.time != null) {
      if (now.hour == schedule.time!.hour &&
          now.minute == schedule.time!.minute) {
        startJob(jobId);
      }
    } else if (schedule.type == ScheduleType.weekly && schedule.time != null) {
      final today = DateTime.now().weekday;
      if (schedule.weekDays.contains(today) &&
          now.hour == schedule.time!.hour &&
          now.minute == schedule.time!.minute) {
        startJob(jobId);
      }
    } else if (schedule.type == ScheduleType.interval) {
      // Interval timer fires directly — just sync.
      startJob(jobId);
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Helpers
  // ═══════════════════════════════════════════════════════════════════════════

  ServerSyncJob? _findJob(String id) => state.jobById(id);

  void _updateJob(ServerSyncJob updated) {
    final jobs =
        state.jobs.map((j) => j.id == updated.id ? updated : j).toList();
    state = state.copyWith(jobs: jobs);
  }

  String _remotePath(SftpServerConfig server, ServerSyncJob job) {
    var base = server.remotePath;
    if (!base.endsWith('/')) base = '$base/';
    if (job.remoteSubPath.isNotEmpty) {
      return '$base${job.remoteSubPath}'.replaceAll('//', '/');
    }
    return base.endsWith('/') ? base.substring(0, base.length - 1) : base;
  }

  /// Build a local manifest by scanning [job.sourceDirectory].
  Future<SyncManifest> _buildLocalManifest(ServerSyncJob job) async {
    final entries = <SyncManifestEntry>[];
    final dir = Directory(job.sourceDirectory);
    int yieldCounter = 0;
    await for (final entity in dir.list(recursive: true)) {
      if (entity is! File) continue;
      final relativePath = p
          .relative(entity.path, from: job.sourceDirectory)
          .replaceAll(r'\', '/');

      if (!matchesSyncFilters(
        relativePath,
        includePatterns: job.includePatterns,
        excludePatterns: job.excludePatterns,
      )) {
        continue;
      }

      final stat = await entity.stat();
      entries.add(SyncManifestEntry(
        relativePath: relativePath,
        size: stat.size,
        lastModified: stat.modified.toUtc(),
      ));

      // Yield periodically to keep UI responsive.
      if (++yieldCounter % 100 == 0) {
        await Future<void>.delayed(Duration.zero);
      }
    }
    return SyncManifest(
      deviceId: 'local',
      basePath: job.sourceDirectory,
      createdAt: DateTime.now().toUtc(),
      entries: entries,
    );
  }

  @override
  void dispose() {
    stopAll();
    super.dispose();
  }
}
