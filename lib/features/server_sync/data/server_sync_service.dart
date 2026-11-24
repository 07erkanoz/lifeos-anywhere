import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:crypto/crypto.dart';
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
import 'package:anyware/features/server_sync/data/ftp_cloud_transport.dart';
import 'package:anyware/features/server_sync/data/webdav_cloud_transport.dart';
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

// ── Pure helpers (exposed for tests) ─────────────────────────────────────────

/// Whether [rel] is a plain relative path that cannot escape the sync root.
bool isSafeRelativePath(String rel) {
  if (rel.isEmpty || rel.startsWith('/') || rel.startsWith(r'\')) {
    return false;
  }
  if (rel.contains('\u0000')) return false;
  if (RegExp(r'^[A-Za-z]:').hasMatch(rel)) return false; // drive letter
  for (final seg in rel.split(RegExp(r'[/\\]'))) {
    if (seg.isEmpty || seg == '.' || seg == '..') return false;
  }
  return true;
}

/// Resolves [rel] under [root] and returns the absolute local path, or null
/// when the result would not be inside [root] (path traversal).
String? safeLocalPath(String root, String rel) {
  if (!isSafeRelativePath(rel)) return null;
  final full = p.normalize(p.join(root, rel.replaceAll('/', p.separator)));
  if (!p.isWithin(p.normalize(root), full)) return null;
  return full;
}

/// "Due since last run" check for daily/weekly schedules: true when the most
/// recent scheduled occurrence at or before [now] is after [since] (or
/// [since] is null). A late or missed timer tick therefore runs the job at
/// the next tick instead of skipping a whole day/week.
bool isScheduleDue(SyncSchedule schedule,
    {required DateTime? since, required DateTime now}) {
  if (!schedule.enabled) return false;
  if (schedule.type == ScheduleType.interval) return true;
  final time = schedule.time;
  if (time == null) return false;

  DateTime? latest;
  for (var back = 0; back <= 7; back++) {
    final day = DateTime(now.year, now.month, now.day - back);
    final occ = DateTime(day.year, day.month, day.day, time.hour, time.minute);
    if (occ.isAfter(now)) continue;
    if (schedule.type == ScheduleType.weekly &&
        !schedule.weekDays.contains(occ.weekday)) {
      continue;
    }
    latest = occ;
    break;
  }
  if (latest == null) return false;
  return since == null || latest.isAfter(since);
}

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

  /// Secure storage for account credentials (password, private key,
  /// passphrase). Non-secret account fields stay in SharedPreferences.
  static const _secure = FlutterSecureStorage();
  static String _secretKey(String accountId) => 'sync_account_secrets_$accountId';

  /// Load accounts from SharedPreferences (+ secrets from secure storage),
  /// migrating the legacy format and any plaintext credentials.
  Future<void> _loadAccounts() async {
    try {
      final prefs = await _prefs;

      final raw = prefs.getString(_prefAccounts);
      if (raw != null) {
        final rawList = (jsonDecode(raw) as List<dynamic>)
            .cast<Map<String, dynamic>>();
        var hadPlaintext = false;
        final list = <SyncAccount>[];
        for (final json in rawList) {
          var account = SyncAccount.fromJson(json);
          if (SyncAccount.secretKeys.any((k) => json[k] != null)) {
            hadPlaintext = true;
          }
          final stored = await _readSecrets(account.id);
          if (stored != null) {
            account = account.withSecrets(stored);
          }
          // else: keep the plaintext values; they get moved below.
          list.add(account);
        }
        state = state.copyWith(accounts: list);
        if (hadPlaintext) {
          _log.info('Moving account credentials to secure storage');
          await _saveAccounts();
        }
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
        final secured = await _saveAccounts();
        // The legacy key holds plaintext passwords: drop it once the
        // credentials are safely in secure storage.
        if (secured) await prefs.remove(_prefLegacyServers);
      }
    } catch (e) {
      _log.error('Failed to load accounts: $e', error: e);
    }
  }

  Future<Map<String, dynamic>?> _readSecrets(String accountId) async {
    try {
      final v = await _secure.read(key: _secretKey(accountId));
      if (v == null) return null;
      return jsonDecode(v) as Map<String, dynamic>;
    } catch (e) {
      _log.warning('Secure storage read failed for $accountId: $e');
      return null;
    }
  }

  /// Persists accounts: credentials to secure storage, everything else to
  /// SharedPreferences. Returns false if secure storage was unavailable, in
  /// which case that account's credentials stay in SharedPreferences rather
  /// than being lost.
  Future<bool> _saveAccounts() async {
    final prefs = await _prefs;
    var allSecured = true;
    final json = <Map<String, dynamic>>[];
    for (final a in state.accounts) {
      var secured = true;
      try {
        // Never delete here: an account whose secrets could not be read
        // (transient keyring error) must not have them wiped on save.
        if (a.hasSecrets) {
          await _secure.write(
              key: _secretKey(a.id), value: jsonEncode(a.secrets));
        }
      } catch (e) {
        secured = false;
        allSecured = false;
        _log.error('Secure storage unavailable, keeping credentials of '
            '"${a.name}" in preferences: $e');
      }
      json.add(a.toJson(includeSecrets: !secured));
    }
    await prefs.setString(_prefAccounts, jsonEncode(json));
    return allSecured;
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

    try {
      await _secure.delete(key: _secretKey(accountId));
    } catch (_) {}
    await _transport.resetHostKey(accountId);

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

  /// Forgets the pinned SSH host key of an SFTP account, so the next connect
  /// trusts (and pins) the key the server presents. For the UI to call after
  /// the user confirmed a legitimate server key change.
  Future<void> resetHostKey(String accountId) =>
      _transport.resetHostKey(accountId);

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
    final job = _findJob(jobId);
    stopJob(jobId);
    await SyncManifestStore.instance.deleteManifests(
        '${(job?.providerType ?? SyncProviderType.sftp).name}_$jobId');
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

  /// Starts a full sync pass of [jobId]. Allowed from idle, error and
  /// watching (a scheduled run of a live-watching job).
  ///
  /// [allowMassDeletion] bypasses the mass-deletion guard once — for the UI
  /// after the user confirmed that the deletions are intended
  /// (see [confirmMassDeletion]).
  Future<void> startJob(String jobId, {bool allowMassDeletion = false}) async {
    var job = _findJob(jobId);
    if (job == null) return;
    if (job.phase != SyncJobPhase.idle &&
        job.phase != SyncJobPhase.error &&
        job.phase != SyncJobPhase.watching) {
      return;
    }
    _lastScheduleAttempt[jobId] = DateTime.now();

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
      await _executeSyncJob(jobId, account, cancelToken,
          allowMassDeletion: allowMassDeletion);
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

  /// Runs [jobId] once with the mass-deletion guard disabled, after the user
  /// confirmed that the many deletions it reported are intended.
  Future<void> confirmMassDeletion(String jobId) async {
    final job = _findJob(jobId);
    if (job == null) return;
    if (job.phase == SyncJobPhase.watching) {
      stopJob(jobId);
    }
    await startJob(jobId, allowMassDeletion: true);
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
      case SyncProviderType.webdav:
        return WebDavCloudTransport(
          url: _buildWebDavUrl(account),
          username: account.username ?? '',
          password: account.password ?? '',
          basePath: account.remotePath,
        );
      case SyncProviderType.ftp:
        return FtpCloudTransport(
          host: account.host ?? '',
          port: account.port ?? 21,
          username: account.username ?? '',
          password: account.password ?? '',
          basePath: account.remotePath,
        );
    }
  }

  /// Build the WebDAV URL from [account].
  ///
  /// If the host field already contains a full URL (starts with http:// or
  /// https://), use it as-is. This lets users specify a custom path like
  /// `https://seafile.example.com/seafdav/`. Otherwise, build the URL from
  /// host + port as before.
  static String _buildWebDavUrl(SyncAccount account) {
    final host = account.host ?? '';
    if (host.startsWith('http://') || host.startsWith('https://')) {
      // Strip trailing slash for consistency — webdav_client adds its own.
      return host.endsWith('/') ? host.substring(0, host.length - 1) : host;
    }
    final port = account.port ?? 443;
    final scheme = port == 443 ? 'https' : 'http';
    return '$scheme://$host:$port';
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Quick upload (single files to server, no sync job needed)
  // ═══════════════════════════════════════════════════════════════════════════

  /// Uploads files to a server account without requiring a sync job.
  ///
  /// Yields `(completedCount, totalCount, currentFileName)` for progress
  /// tracking. Throws if the account is not found or the connection fails.
  Stream<(int, int, String)> uploadFilesToAccount(
    String accountId,
    List<String> localPaths,
    String remoteDir,
  ) async* {
    final account = state.accountById(accountId);
    if (account == null) throw Exception('Account not found');

    final transport = _createTransport(account);
    try {
      await transport.connect();
      await transport.ensureRemoteDir(remoteDir);

      for (int i = 0; i < localPaths.length; i++) {
        final localPath = localPaths[i];
        final fileName = localPath.split(Platform.pathSeparator).last;
        yield (i, localPaths.length, fileName);

        final remotePath = remoteDir.endsWith('/')
            ? '$remoteDir$fileName'
            : '$remoteDir/$fileName';
        final err = await transport.uploadFile(localPath, remotePath);
        if (err != null) {
          throw Exception('Upload failed ($fileName): $err');
        }
      }
      yield (localPaths.length, localPaths.length, '');

      // Update lastConnectedAt on success.
      await updateAccount(account.copyWith(lastConnectedAt: DateTime.now()));
    } finally {
      await transport.disconnect();
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Sync execution
  // ═══════════════════════════════════════════════════════════════════════════

  Future<void> _executeSyncJob(
    String jobId,
    SyncAccount account,
    CancellationToken cancelToken, {
    bool allowMassDeletion = false,
  }) async {
    var job = _findJob(jobId);
    if (job == null) return;

    final transport = _createTransport(account);
    final storeKey = '${account.providerType.name}_$jobId';

    void fail(String status) {
      final j = _findJob(jobId);
      if (j != null) {
        _updateJob(j.copyWith(phase: SyncJobPhase.error, status: status));
        _saveJobs();
      }
    }

    // ── 1. Connect ──
    _updateJob(job.copyWith(status: 'serverSyncConnecting'));
    try {
      await transport.connect();
    } on SftpHostKeyChangedException catch (e) {
      _log.error('Host key changed for ${account.name}: $e');
      fail(e.toString());
      return;
    } catch (e) {
      _log.error('Connect failed for ${account.name}: $e');
      fail('serverSyncDisconnected');
      return;
    }

    try {
      // ── 2. Scan local folder ──
      job = _findJob(jobId);
      if (job == null || job.phase == SyncJobPhase.idle) return;
      _updateJob(job.copyWith(status: 'syncBuildingManifest'));

      final ScanResult scan;
      try {
        scan = await _scanLocal(job);
      } catch (e) {
        // Never continue with an empty/partial manifest.
        _log.error('Local scan failed for job $jobId: $e');
        fail('Local scan failed: $e');
        return;
      }
      if (scan.isPartial) {
        _log.warning('Job "$jobId": unreadable local paths are left alone: '
            '${scan.unknownPaths.take(20).join(', ')}');
      }
      final localManifest = SyncManifest(
        deviceId: 'local',
        basePath: job.sourceDirectory,
        createdAt: DateTime.now().toUtc(),
        entries: scan.entries,
      );
      final localMap = localManifest.toMap();

      // ── 3. List remote folder ──
      job = _findJob(jobId);
      if (job == null || job.phase == SyncJobPhase.idle) return;
      _updateJob(job.copyWith(status: 'serverSyncScanning'));

      final remotePath = _remotePathForAccount(account, job);
      final SyncManifest remoteManifest;
      try {
        await transport.ensureRemoteDir(remotePath);
        remoteManifest = _sanitizeRemoteManifest(
            await transport.buildRemoteManifest(remotePath, account.id));
      } catch (e) {
        // A failed or partial listing must never drive deletions.
        _log.error('Remote listing failed for job $jobId: $e');
        fail('Remote listing failed: $e');
        return;
      }
      final remoteMap = remoteManifest.toMap();

      // ── 4. Compute diff ──
      final store = SyncManifestStore.instance;
      final prevLocal = await store.loadLocalManifest(storeKey);
      final prevRemote = await store.loadRemoteManifest(storeKey);
      final prevLocalMap = prevLocal?.toMap() ?? const {};
      final prevRemoteMap = prevRemote?.toMap() ?? const {};
      final unknownPaths = scan.unknownPaths;
      final oneWay = job.syncDirection == SyncDirection.oneWay;

      _updateJob(job.copyWith(status: 'syncComputingDiff'));
      final plan = computeSyncPlan(
        local: localManifest,
        remote: remoteManifest,
        previousLocal: prevLocal,
        previousRemote: prevRemote,
        conflictStrategy: job.conflictStrategy,
        mirrorDeletions: job.mirrorDeletions,
        direction: job.syncDirection,
        localUnknownPaths: unknownPaths,
      );

      _log.info('Job "$jobId" (${job.syncDirection.name}) plan: '
          '${plan.sends.length} send, ${plan.pulls.length} pull, '
          '${plan.localDeletes.length} localDel, '
          '${plan.remoteDeletes.length} remoteDel, '
          '${plan.conflicts.length} conflicts');

      if (!allowMassDeletion) {
        final reason = massDeletionReason(
          plan: plan,
          previousLocal: prevLocal,
          previousRemote: prevRemote,
        );
        if (reason != null) {
          _log.warning('Job "$jobId": $reason — sync stopped');
          fail('$reason. Nothing was changed. Check that both folders are '
              'available; if the deletions are intended, confirm them.');
          return;
        }
      }

      // ── 5. New base = state AFTER the run ──
      // Paths without an action keep their current (pre-run) state; paths
      // with an action get their post-action state on success and keep the
      // previous base on failure (so they are retried, not "forgotten").
      final planPaths = plan.actions.map((a) => a.relativePath).toSet();
      final baseLocal = <String, SyncManifestEntry>{};
      final baseRemote = <String, SyncManifestEntry>{};
      void keepPrevious(String path) {
        final pl = prevLocalMap[path];
        final pr = prevRemoteMap[path];
        if (pl != null) {
          baseLocal[path] = pl;
        } else {
          baseLocal.remove(path);
        }
        if (pr != null) {
          baseRemote[path] = pr;
        } else {
          baseRemote.remove(path);
        }
      }

      for (final e in localManifest.entries) {
        if (!planPaths.contains(e.relativePath)) baseLocal[e.relativePath] = e;
      }
      for (final e in remoteManifest.entries) {
        if (!planPaths.contains(e.relativePath) &&
            !isUnderAny(e.relativePath, unknownPaths)) {
          baseRemote[e.relativePath] = e;
        }
      }
      // Unreadable local paths: their state is unknown, keep the old base.
      for (final path in {...prevLocalMap.keys, ...prevRemoteMap.keys}) {
        if (isUnderAny(path, unknownPaths)) keepPrevious(path);
      }
      for (final path in planPaths) {
        keepPrevious(path);
      }

      // Paths uploaded this run whose remote metadata is refreshed at the end.
      final uploaded = <String>{};
      void markUploaded(String path, SyncManifestEntry local) {
        uploaded.add(path);
        // Provisional, replaced by the real listing entry below.
        baseRemote[path] = SyncManifestEntry(
          relativePath: path,
          size: local.size,
          lastModified: local.lastModified,
        );
      }

      // ── 6. Execute ──
      final actions = plan.actions;
      final fileItems = actions
          .map((a) => SyncFileItem(
                relativePath: a.relativePath,
                status: SyncFileStatus.pending,
                fileSize: a.localEntry?.size ?? a.remoteEntry?.size ?? 0,
              ))
          .toList();
      final totalBytes = fileItems.fold<int>(0, (sum, f) => sum + f.fileSize);

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

      // The old checkpoint indexed into a different plan; it is not used.
      await store.deleteCheckpoint(storeKey);

      int successCount = 0;
      int transferred = 0;
      final failures = <SyncError>[];
      final sourceDir = job.sourceDirectory;
      String remoteOf(String rel) =>
          remotePath.endsWith('/') ? '$remotePath$rel' : '$remotePath/$rel';

      for (int i = 0; i < actions.length; i++) {
        if (cancelToken.isCancelled) {
          _log.info('Sync cancelled for job $jobId at index $i');
          break;
        }

        job = _findJob(jobId);
        if (job == null || job.phase == SyncJobPhase.idle) break;
        while (job != null && job.phase == SyncJobPhase.paused) {
          await Future<void>.delayed(const Duration(milliseconds: 500));
          job = _findJob(jobId);
        }
        if (job == null || job.phase == SyncJobPhase.idle) break;

        final action = actions[i];
        final rel = action.relativePath;
        final items = List<SyncFileItem>.from(job.fileItems);
        items[i] = items[i].copyWith(status: SyncFileStatus.syncing);
        _updateJob(job.copyWith(fileItems: items));

        String? error;
        final localPath = safeLocalPath(sourceDir, rel);

        if (localPath == null) {
          error = 'Unsafe path rejected: $rel';
        } else if (oneWay &&
            (action.type == SyncActionType.pullFromRemote ||
                action.type == SyncActionType.deleteLocal ||
                action.type == SyncActionType.conflict)) {
          // One-way never changes local files (the plan never asks for it).
          error = 'Skipped: one-way job may not change local files';
        } else {
          try {
            switch (action.type) {
              case SyncActionType.sendToRemote:
                error = await transport.uploadFile(
                  localPath,
                  remoteOf(rel),
                  cancel: cancelToken,
                );
                if (error == null) {
                  baseLocal[rel] = action.localEntry!;
                  markUploaded(rel, action.localEntry!);
                }
                break;

              case SyncActionType.pullFromRemote:
                error = await _downloadVerified(
                  transport,
                  remoteOf(rel),
                  localPath,
                  action.remoteEntry!,
                  cancelToken,
                );
                if (error == null) {
                  baseRemote[rel] = action.remoteEntry!;
                  baseLocal[rel] = await _statEntry(rel, localPath);
                }
                break;

              case SyncActionType.deleteLocal:
                final f = File(localPath);
                if (await f.exists()) await f.delete();
                baseLocal.remove(rel);
                baseRemote.remove(rel);
                break;

              case SyncActionType.deleteRemote:
                final ok = await transport.deleteRemoteFile(remoteOf(rel));
                if (ok) {
                  baseLocal.remove(rel);
                  baseRemote.remove(rel);
                } else {
                  error = 'Failed to delete remote file';
                }
                break;

              case SyncActionType.conflict:
                error = await _keepBoth(
                  transport: transport,
                  account: account,
                  action: action,
                  sourceDir: sourceDir,
                  localPath: localPath,
                  remoteOf: remoteOf,
                  localMap: localMap,
                  remoteMap: remoteMap,
                  baseLocal: baseLocal,
                  baseRemote: baseRemote,
                  markUploaded: markUploaded,
                  cancel: cancelToken,
                );
                break;
            }
          } catch (e) {
            error = e.toString();
          }
        }

        job = _findJob(jobId);
        if (job == null) break;
        final updatedItems = List<SyncFileItem>.from(job.fileItems);
        if (error == null) {
          successCount++;
          transferred += updatedItems[i].fileSize;
          updatedItems[i] = updatedItems[i].copyWith(
            status: SyncFileStatus.completed,
            completedAt: DateTime.now(),
          );
        } else {
          failures.add(SyncError(
            filePath: rel,
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

      // ── 7. Refresh remote metadata of uploaded files, save the base ──
      if (uploaded.isNotEmpty && !cancelToken.isCancelled) {
        try {
          final after = _sanitizeRemoteManifest(
                  await transport.buildRemoteManifest(remotePath, account.id))
              .toMap();
          for (final path in uploaded) {
            final e = after[path];
            if (e != null) baseRemote[path] = e;
          }
        } catch (e) {
          _log.warning('Post-sync remote listing failed (using local '
              'metadata for uploaded files): $e');
        }
      }

      final now = DateTime.now().toUtc();
      await store.saveLocalManifest(
          storeKey,
          SyncManifest(
            deviceId: 'local',
            basePath: sourceDir,
            createdAt: now,
            entries: baseLocal.values.toList(),
          ));
      await store.saveRemoteManifest(
          storeKey,
          SyncManifest(
            deviceId: remoteManifest.deviceId,
            basePath: remoteManifest.basePath,
            createdAt: now,
            entries: baseRemote.values.toList(),
          ));

      job = _findJob(jobId);
      if (job != null && job.phase != SyncJobPhase.idle) {
        _updateJob(job.copyWith(
          phase: job.liveWatch ? SyncJobPhase.watching : SyncJobPhase.idle,
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

  /// Keep-both conflict: the remote version is saved locally as
  /// `name (conflict <account> <date>).ext`, the local version replaces the
  /// remote file, and the conflict copy is uploaded too — both survive on
  /// both sides. Returns an error message or null.
  Future<String?> _keepBoth({
    required CloudTransport transport,
    required SyncAccount account,
    required SyncAction action,
    required String sourceDir,
    required String localPath,
    required String Function(String) remoteOf,
    required Map<String, SyncManifestEntry> localMap,
    required Map<String, SyncManifestEntry> remoteMap,
    required Map<String, SyncManifestEntry> baseLocal,
    required Map<String, SyncManifestEntry> baseRemote,
    required void Function(String, SyncManifestEntry) markUploaded,
    required CancellationToken cancel,
  }) async {
    final rel = action.relativePath;
    final now = DateTime.now();
    var copyRel = conflictCopyPath(rel, account.name, now);
    for (var n = 2;
        localMap.containsKey(copyRel) ||
            remoteMap.containsKey(copyRel) ||
            await File(safeLocalPath(sourceDir, copyRel) ?? '').exists();
        n++) {
      copyRel = conflictCopyPath(rel, '${account.name} $n', now);
    }
    final copyLocal = safeLocalPath(sourceDir, copyRel);
    if (copyLocal == null) return 'Unsafe conflict path: $copyRel';

    // 1. Preserve the remote version locally under the conflict name.
    final err = await _downloadVerified(
        transport, remoteOf(rel), copyLocal, action.remoteEntry!, cancel);
    if (err != null) return 'Conflict copy failed: $err';
    final copyEntry = await _statEntry(copyRel, copyLocal);
    baseLocal[copyRel] = copyEntry;
    // The remote version is now safe locally: remote counts as handled.
    baseRemote[rel] = action.remoteEntry!;

    // 2. Local version replaces the remote file.
    final up = await transport.uploadFile(localPath, remoteOf(rel),
        cancel: cancel);
    if (up != null) return 'Upload of local version failed: $up';
    baseLocal[rel] = action.localEntry!;
    markUploaded(rel, action.localEntry!);

    // 3. Upload the conflict copy so the remote side has both as well.
    final up2 = await transport.uploadFile(copyLocal, remoteOf(copyRel),
        cancel: cancel);
    if (up2 == null) {
      markUploaded(copyRel, copyEntry);
    } else {
      // Not fatal: the copy is a new local file and is sent next run.
      _log.warning('Conflict copy upload failed ($copyRel): $up2');
    }
    _log.info('Conflict on $rel: kept both (remote copy → $copyRel)');
    return null;
  }

  /// Downloads into a `.sync_dl` staging file, verifies size (and hash when
  /// the provider's hash kind is known), and only then replaces [localPath].
  Future<String?> _downloadVerified(
    CloudTransport transport,
    String remoteFile,
    String localPath,
    SyncManifestEntry expected,
    CancellationToken cancel,
  ) async {
    final staging = File('$localPath.sync_dl');
    try {
      final err = await transport.downloadFile(remoteFile, staging.path,
          cancel: cancel);
      if (err != null) return err;
      if (!await staging.exists()) return 'Download produced no file';

      final got = await staging.length();
      if (expected.size > 0 && got != expected.size) {
        return 'Downloaded size $got != expected ${expected.size}';
      }
      final want = expected.hash?.toLowerCase();
      if (want != null && RegExp(r'^[0-9a-f]+$').hasMatch(want)) {
        final Hash? algo = switch (want.length) {
          32 => md5,
          40 => sha1,
          64 => sha256,
          _ => null,
        };
        if (algo != null) {
          final digest = await algo.bind(staging.openRead()).first;
          if (digest.toString() != want) {
            return 'Downloaded file hash mismatch';
          }
        }
      }
      await replaceLocalFile(staging, localPath);
      return null;
    } catch (e) {
      return e.toString();
    } finally {
      try {
        if (await staging.exists()) await staging.delete();
      } catch (_) {}
    }
  }

  Future<SyncManifestEntry> _statEntry(String rel, String path) async {
    final st = await File(path).stat();
    return SyncManifestEntry(
      relativePath: rel,
      size: st.size,
      lastModified: st.modified.toUtc(),
    );
  }

  /// Drops temp files and paths that could escape the sync root from a
  /// remote listing.
  SyncManifest _sanitizeRemoteManifest(SyncManifest m) {
    final kept = <SyncManifestEntry>[];
    for (final e in m.entries) {
      if (isSyncTempPath(e.relativePath)) continue;
      if (!isSafeRelativePath(e.relativePath)) {
        _log.warning('Ignoring unsafe remote path: ${e.relativePath}');
        continue;
      }
      kept.add(e);
    }
    return SyncManifest(
      deviceId: m.deviceId,
      basePath: m.basePath,
      createdAt: m.createdAt,
      entries: kept,
    );
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

      final uploadedEntries = <SyncManifestEntry>[];
      for (final filePath in pending) {
        if (isSyncTempPath(filePath)) continue;
        if (!p.isWithin(job.sourceDirectory, filePath)) continue;
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
        } else {
          try {
            uploadedEntries.add(await _statEntry(relativePath, filePath));
          } catch (_) {}
        }
      }
      // Record the pushed files in the base so the next full run does not
      // see them as changed on both sides (spurious conflicts).
      if (uploadedEntries.isNotEmpty) {
        await _recordLiveUploads(account, job, uploadedEntries);
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

  Future<void> _recordLiveUploads(
    SyncAccount account,
    ServerSyncJob job,
    List<SyncManifestEntry> entries,
  ) async {
    try {
      final storeKey = '${account.providerType.name}_${job.id}';
      final store = SyncManifestStore.instance;
      final prevL = await store.loadLocalManifest(storeKey);
      final prevR = await store.loadRemoteManifest(storeKey);
      final l = prevL?.toMap() ?? <String, SyncManifestEntry>{};
      final r = prevR?.toMap() ?? <String, SyncManifestEntry>{};
      for (final e in entries) {
        l[e.relativePath] = e;
        r[e.relativePath] = SyncManifestEntry(
          relativePath: e.relativePath,
          size: e.size,
          lastModified: e.lastModified,
        );
      }
      final now = DateTime.now().toUtc();
      await store.saveLocalManifest(
          storeKey,
          SyncManifest(
              deviceId: 'local',
              basePath: job.sourceDirectory,
              createdAt: now,
              entries: l.values.toList()));
      await store.saveRemoteManifest(
          storeKey,
          SyncManifest(
              deviceId: prevR?.deviceId ?? account.id,
              basePath: prevR?.basePath ?? '',
              createdAt: now,
              entries: r.values.toList()));
    } catch (e) {
      _log.warning('Could not record live uploads in base manifest: $e');
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Schedule
  // ═══════════════════════════════════════════════════════════════════════════

  /// When each job's schedule timer started (lower bound for "due since").
  final Map<String, DateTime> _scheduleAnchors = {};

  /// Last time a run of each job was started (scheduled or manual), so a
  /// failing job is not retried on every minute tick.
  final Map<String, DateTime> _lastScheduleAttempt = {};

  void _startScheduleTimer(ServerSyncJob job) {
    _scheduleTimers[job.id]?.cancel();
    final schedule = job.schedule;
    if (schedule == null || !schedule.enabled) return;
    _scheduleAnchors.putIfAbsent(job.id, DateTime.now);

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
    if (job == null) return;
    // A live-watching job must still get its scheduled full pass (it picks
    // up remote changes and anything the watcher missed). Error is retried.
    if (job.phase != SyncJobPhase.idle &&
        job.phase != SyncJobPhase.watching &&
        job.phase != SyncJobPhase.error) {
      return;
    }

    final schedule = job.schedule;
    if (schedule == null || !schedule.enabled) return;

    if (schedule.type == ScheduleType.interval) {
      // Interval timer fires directly — just sync.
      startJob(jobId);
      return;
    }

    DateTime? since = job.lastSyncTime;
    for (final t in [_lastScheduleAttempt[jobId], _scheduleAnchors[jobId]]) {
      if (t != null && (since == null || t.isAfter(since))) since = t;
    }
    if (isScheduleDue(schedule, since: since, now: DateTime.now())) {
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
    var result = account.remotePath;
    // Remove trailing slashes (keep single '/' for root).
    while (result.length > 1 && result.endsWith('/')) {
      result = result.substring(0, result.length - 1);
    }
    // Append subpath if present.
    if (job.remoteSubPath.isNotEmpty) {
      var sub = job.remoteSubPath;
      if (sub.startsWith('/')) sub = sub.substring(1);
      while (sub.endsWith('/')) {
        sub = sub.substring(0, sub.length - 1);
      }
      if (sub.isNotEmpty) {
        result = result == '/' ? '/$sub' : '$result/$sub';
      }
    }
    return result;
  }

  /// Scans [job.sourceDirectory] in a background isolate (SHA-256 for files
  /// up to 50 MB). Throws if the folder is missing or unreadable.
  Future<ScanResult> _scanLocal(ServerSyncJob job) {
    return scanDirectoryInIsolate(ScanParams(
      dirPath: job.sourceDirectory,
      includePatterns: job.includePatterns,
      excludePatterns: job.excludePatterns,
      hashThresholdBytes: 50 * 1024 * 1024, // 50 MB
    ));
  }

  @override
  void dispose() {
    stopAll();
    super.dispose();
  }
}
