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
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:anyware/features/server_sync/data/cloud_transport.dart';
import 'package:anyware/features/server_sync/data/gdrive_transport.dart';
import 'package:anyware/features/server_sync/data/oauth_service.dart';
import 'package:anyware/features/server_sync/data/onedrive_transport.dart';
import 'package:anyware/features/server_sync/data/sftp_cloud_transport.dart';
import 'package:anyware/features/server_sync/data/sftp_transport.dart';
import 'package:anyware/features/server_sync/data/token_store.dart';
import 'package:anyware/features/server_sync/domain/server_sync_job.dart';
import 'package:anyware/features/server_sync/domain/server_sync_state.dart';
import 'package:anyware/features/server_sync/domain/sftp_server_config.dart';
import 'package:anyware/features/server_sync/domain/sync_account.dart';
import 'package:anyware/features/sync/data/cancellation_token.dart';
import 'package:anyware/features/sync/data/sync_diff_engine.dart';
import 'package:anyware/features/sync/data/sync_filter_utils.dart';
import 'package:anyware/features/sync/data/sync_manifest_store.dart';
import 'package:anyware/features/sync/data/isolate_scanner.dart';
import 'package:anyware/features/sync/domain/sync_manifest.dart';
import 'package:anyware/features/sync/domain/sync_state.dart';

final _log = AppLogger('ServerSyncService');
const _uuid = Uuid();

// ── Providers ────────────────────────────────────────────────────────────────

final sftpTransportProvider = Provider((_) => SftpTransport());
final tokenStoreProvider = Provider((_) => TokenStore(const FlutterSecureStorage()));
final oauthServiceProvider = Provider((ref) => OAuthService(ref.read(tokenStoreProvider)));

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

  static const _prefAccounts = 'sync_accounts_v1';
  static const _prefLegacyServers = 'sftp_servers_v1';
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

  // Per-job cancellation tokens for cooperative cancellation.
  final Map<String, CancellationToken> _cancelTokens = {};

  // ═══════════════════════════════════════════════════════════════════════════
  // Initialisation & persistence
  // ═══════════════════════════════════════════════════════════════════════════

  Future<void> _init() async {
    await _loadAccounts();
    await _loadJobs();
    // Auto-resume jobs that were running before the app closed.
    Future.delayed(const Duration(seconds: 4), _autoResumeJobs);
  }

  Future<SharedPreferences> get _prefs => SharedPreferences.getInstance();

  /// Load accounts from SharedPreferences, with migration from legacy format.
  Future<void> _loadAccounts() async {
    try {
      final prefs = await _prefs;

      // Try new format first.
      final raw = prefs.getString(_prefAccounts);
      if (raw != null) {
        final list = (jsonDecode(raw) as List<dynamic>)
            .map((e) => SyncAccount.fromJson(e as Map<String, dynamic>))
            .toList();
        state = state.copyWith(accounts: list);
        return;
      }

      // Migration: read legacy sftp_servers_v1 format.
      final legacyRaw = prefs.getString(_prefLegacyServers);
      if (legacyRaw != null) {
        _log.info('Migrating legacy sftp_servers_v1 to sync_accounts_v1');
        final legacyList = (jsonDecode(legacyRaw) as List<dynamic>)
            .map((e) =>
                SftpServerConfig.fromJson(e as Map<String, dynamic>))
            .toList();
        final accounts = legacyList
            .map((s) => SyncAccount.fromSftpConfig(s))
            .toList();
        state = state.copyWith(accounts: accounts);
        await _saveAccounts();
        // Keep legacy key for rollback safety.
      }
    } catch (e) {
      _log.error('Failed to load accounts: $e', error: e);
    }
  }

  Future<void> _saveAccounts() async {
    final prefs = await _prefs;
    final json = state.accounts.map((a) => a.toJson()).toList();
    await prefs.setString(_prefAccounts, jsonEncode(json));
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
  // Account CRUD
  // ═══════════════════════════════════════════════════════════════════════════

  Future<String> addAccount(SyncAccount account) async {
    state = state.copyWith(accounts: [...state.accounts, account]);
    await _saveAccounts();
    return account.id;
  }

  Future<void> updateAccount(SyncAccount account) async {
    final accounts = state.accounts.map((a) {
      return a.id == account.id ? account : a;
    }).toList();
    state = state.copyWith(accounts: accounts);
    await _saveAccounts();
  }

  Future<void> deleteAccount(String accountId) async {
    final account = state.accountById(accountId);

    // Stop and remove all jobs for this account.
    final jobsToRemove =
        state.jobs.where((j) => j.serverId == accountId).toList();
    for (final job in jobsToRemove) {
      stopJob(job.id);
      final storeKey = '${job.providerType.name}_${job.id}';
      await SyncManifestStore.instance.deleteManifests(storeKey);
    }

    // Revoke OAuth token for cloud accounts.
    if (account != null && account.isCloud) {
      try {
        await ref.read(oauthServiceProvider).revokeToken(accountId);
      } catch (e) {
        _log.error('Token revocation failed during account delete: $e');
      }
    }

    final remainingJobs =
        state.jobs.where((j) => j.serverId != accountId).toList();
    final remainingAccounts =
        state.accounts.where((a) => a.id != accountId).toList();
    state = state.copyWith(accounts: remainingAccounts, jobs: remainingJobs);
    await _saveAccounts();
    await _saveJobs();
  }

  Future<bool> testAccount(String accountId) async {
    final account = state.accountById(accountId);
    if (account == null) return false;

    final transport = _createTransport(account);
    try {
      final ok = await transport.testConnection();
      if (ok) {
        await updateAccount(
            account.copyWith(lastConnectedAt: DateTime.now()));
      }
      return ok;
    } catch (e) {
      _log.error('Test account failed: $e');
      return false;
    }
  }

  // ── Backward compatibility aliases ──

  /// @deprecated Use [addAccount] instead.
  Future<String> addServer(SftpServerConfig server) async =>
      addAccount(SyncAccount.fromSftpConfig(server));

  /// @deprecated Use [updateAccount] instead.
  Future<void> updateServer(SftpServerConfig server) async =>
      updateAccount(SyncAccount.fromSftpConfig(server));

  /// @deprecated Use [deleteAccount] instead.
  Future<void> deleteServer(String serverId) async =>
      deleteAccount(serverId);

  /// @deprecated Use [testAccount] instead.
  Future<bool> testServer(String serverId) async =>
      testAccount(serverId);

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
    final account = state.accountById(serverId);
    final job = ServerSyncJob(
      id: _uuid.v4(),
      name: name,
      sourceDirectory: sourceDirectory,
      serverId: serverId,
      serverName: account?.name ?? '',
      providerType: account?.providerType ?? SyncProviderType.sftp,
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

    final account = state.accountById(job.serverId);
    if (account == null) {
      _updateJob(job.copyWith(
        phase: SyncJobPhase.error,
        status: 'Account not found',
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

    // Create a fresh cancellation token for this sync session.
    _cancelTokens[jobId]?.cancel();
    final cancelToken = CancellationToken();
    _cancelTokens[jobId] = cancelToken;

    // Keep the device awake during SFTP sync operations.
    try {
      await WakelockPlus.enable();
    } catch (_) {}

    // Run the actual sync.
    try {
      await _executeSyncJob(jobId, account, cancelToken);
    } catch (e) {
      _log.error('Sync job $jobId failed: $e', error: e);
      job = _findJob(jobId);
      if (job != null && job.phase != SyncJobPhase.idle) {
        _updateJob(job.copyWith(
          phase: SyncJobPhase.error,
          status: e.toString(),
        ));
      }
    } finally {
      // Release wakelock if no other SFTP jobs are syncing.
      final anyStillSyncing = state.jobs.any(
        (j) => j.id != jobId && j.phase == SyncJobPhase.syncing,
      );
      if (!anyStillSyncing) {
        try {
          await WakelockPlus.disable();
        } catch (_) {}
      }
    }

    // After sync, start live watcher if enabled.
    job = _findJob(jobId);
    if (job != null &&
        job.liveWatch &&
        job.phase != SyncJobPhase.idle &&
        job.phase != SyncJobPhase.error) {
      _startLiveWatch(job, account);
    }

    // Start schedule timer if configured.
    job = _findJob(jobId);
    if (job?.schedule != null && (job!.schedule!.enabled)) {
      _startScheduleTimer(job);
    }
  }

  void stopJob(String jobId) {
    // Cancel any in-flight transfers for this job.
    _cancelTokens[jobId]?.cancel();
    _cancelTokens.remove(jobId);

    _watchers[jobId]?.cancel();
    _watchers.remove(jobId);
    _debouncers[jobId]?.cancel();
    _debouncers.remove(jobId);
    _pendingFiles.remove(jobId);
    _scheduleTimers[jobId]?.cancel();
    _scheduleTimers.remove(jobId);
    _liveSessions[jobId]?.close();
    _liveSessions.remove(jobId);
    _liveTransports[jobId]?.disconnect();
    _liveTransports.remove(jobId);

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
    // Disconnect any leftover cloud transports.
    for (final entry in _liveTransports.entries.toList()) {
      try {
        entry.value.disconnect();
      } catch (_) {}
    }
    _liveTransports.clear();
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
  // Transport factory
  // ═══════════════════════════════════════════════════════════════════════════

  /// Create the appropriate [CloudTransport] for the given [account].
  CloudTransport _createTransport(SyncAccount account) {
    switch (account.providerType) {
      case SyncProviderType.sftp:
        return SftpCloudTransport(
          transport: _transport,
          config: account.toSftpConfig(),
        );
      case SyncProviderType.gdrive:
        return GDriveTransport(
          oauth: ref.read(oauthServiceProvider),
          accountId: account.id,
        );
      case SyncProviderType.onedrive:
        return OneDriveTransport(
          oauth: ref.read(oauthServiceProvider),
          accountId: account.id,
        );
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Sync execution
  // ═══════════════════════════════════════════════════════════════════════════

  Future<void> _executeSyncJob(
    String jobId,
    SyncAccount account,
    CancellationToken cancelToken,
  ) async {
    var job = _findJob(jobId);
    if (job == null) return;

    final transport = _createTransport(account);
    final storeKey = '${account.providerType.name}_$jobId';

    // ── 1. Connect ──
    _updateJob(job.copyWith(status: 'serverSyncConnecting'));
    try {
      await transport.connect();
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

      // ── 3. Build remote manifest (or try delta first) ──
      job = _findJob(jobId);
      if (job == null || job.phase == SyncJobPhase.idle) return;
      _updateJob(job.copyWith(status: 'serverSyncScanning'));

      final remotePath = _remotePathForAccount(account, job);

      // Ensure remote directory exists.
      await transport.ensureRemoteDir(remotePath);

      final remoteManifest = await transport.buildRemoteManifest(
        remotePath,
        account.id,
      );

      // ── 4. Compute diff ──
      final store = SyncManifestStore.instance;
      final prevLocal = await store.loadLocalManifest(storeKey);
      final prevRemote = await store.loadRemoteManifest(storeKey);

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
          await store.saveLocalManifest(storeKey, localManifest);
          await store.saveRemoteManifest(storeKey, remoteManifest);
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

      // ── 6. Execute actions via CloudTransport ──
      int successCount = 0;
      int transferred = 0;
      final failures = <SyncError>[];

      // Load checkpoint for resume-after-crash.
      final checkpoint = await store.loadCheckpoint(storeKey);
      final startIndex =
          (checkpoint >= 0 && checkpoint < allActions.length)
              ? checkpoint + 1
              : 0;

      for (int i = startIndex; i < allActions.length; i++) {
        if (cancelToken.isCancelled) {
          _log.info('Sync cancelled for job $jobId at index $i');
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
            final localPath = p.join(
              job.sourceDirectory,
              action.relativePath.replaceAll('/', p.separator),
            );
            final remoteFilePath =
                '$remotePath/${action.relativePath}';
            error = await transport.uploadFile(
              localPath,
              remoteFilePath,
              onProgress: (bytes) {
                // Throttled progress updates.
              },
              cancel: cancelToken,
            );
            break;

          case SyncActionType.pullFromRemote:
            final localPath = p.join(
              job.sourceDirectory,
              action.relativePath.replaceAll('/', p.separator),
            );
            final remoteFilePath =
                '$remotePath/${action.relativePath}';
            error = await transport.downloadFile(
              remoteFilePath,
              localPath,
              cancel: cancelToken,
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
            final ok = await transport.deleteRemoteFile(remoteFilePath);
            if (!ok) error = 'Failed to delete remote file';
            break;

          case SyncActionType.conflict:
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
          await store.saveCheckpoint(storeKey, i);
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
      await store.deleteCheckpoint(storeKey);
      await store.saveLocalManifest(storeKey, localManifest);
      await store.saveRemoteManifest(storeKey, remoteManifest);

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
      await transport.disconnect();
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Live watch (file system watcher → SFTP push)
  // ═══════════════════════════════════════════════════════════════════════════

  void _startLiveWatch(ServerSyncJob job, SyncAccount account) {
    _watchers[job.id]?.cancel();
    final watcher = DirectoryWatcher(job.sourceDirectory);
    _watchers[job.id] = watcher.events.listen((event) {
      _onLocalFileChange(job.id, event, account);
    });
    _log.info('Live watch started for job ${job.name}');
  }

  void _onLocalFileChange(
      String jobId, WatchEvent event, SyncAccount account) {
    final job = _findJob(jobId);
    if (job == null || job.phase == SyncJobPhase.idle) return;

    _pendingFiles.putIfAbsent(jobId, () => {});
    _pendingFiles[jobId]!.add(event.path);

    // Debounce: wait 3 seconds for batch.
    _debouncers[jobId]?.cancel();
    _debouncers[jobId] = Timer(const Duration(seconds: 3), () {
      _flushPendingFiles(jobId, account);
    });
  }

  /// Per-job transport instances kept alive for live watch mode.
  final Map<String, CloudTransport> _liveTransports = {};

  Future<void> _flushPendingFiles(
      String jobId, SyncAccount account) async {
    final job = _findJob(jobId);
    if (job == null) return;

    final pending = _pendingFiles[jobId]?.toList() ?? [];
    _pendingFiles[jobId]?.clear();
    if (pending.isEmpty) return;

    _log.info('Live watch: flushing ${pending.length} changed files for ${job.name}');
    _updateJob(job.copyWith(phase: SyncJobPhase.syncing, status: 'syncing'));

    try {
      // Reuse existing transport or create new.
      var transport = _liveTransports[jobId];
      if (transport == null) {
        transport = _createTransport(account);
        await transport.connect();
        _liveTransports[jobId] = transport;
      }

      final remotePath = _remotePathForAccount(account, job);

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
        final error = await transport.uploadFile(filePath, remoteFilePath);
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
      // Disconnect broken transport so next flush reconnects.
      try {
        await _liveTransports[jobId]?.disconnect();
      } catch (_) {}
      _liveTransports.remove(jobId);

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

  String _remotePathForAccount(SyncAccount account, ServerSyncJob job) {
    var base = account.remotePath;
    if (!base.endsWith('/')) base = '$base/';
    if (job.remoteSubPath.isNotEmpty) {
      return '$base${job.remoteSubPath}'.replaceAll('//', '/');
    }
    return base.endsWith('/') ? base.substring(0, base.length - 1) : base;
  }

  /// Build a local manifest by scanning [job.sourceDirectory] in a background
  /// isolate with optional SHA-256 hash computation.
  Future<SyncManifest> _buildLocalManifest(ServerSyncJob job) async {
    final result = await scanDirectoryInIsolate(ScanParams(
      dirPath: job.sourceDirectory,
      includePatterns: job.includePatterns,
      excludePatterns: job.excludePatterns,
      hashThresholdBytes: 50 * 1024 * 1024, // 50 MB
    ));
    return SyncManifest(
      deviceId: 'local',
      basePath: job.sourceDirectory,
      createdAt: DateTime.now().toUtc(),
      entries: result.entries,
    );
  }

  @override
  void dispose() {
    stopAll();
    super.dispose();
  }
}
