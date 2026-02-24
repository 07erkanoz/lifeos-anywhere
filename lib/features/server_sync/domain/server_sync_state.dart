import 'package:anyware/features/server_sync/domain/sync_account.dart';
import 'package:anyware/features/server_sync/domain/server_sync_job.dart';
import 'package:anyware/features/sync/domain/sync_state.dart';

/// Top-level state for the Server Sync feature.
class ServerSyncState {
  /// All configured sync accounts (SFTP, Google Drive, OneDrive).
  final List<SyncAccount> accounts;

  final List<ServerSyncJob> jobs;
  final String? activeJobId;
  final List<SyncConflict> pendingConflicts;

  const ServerSyncState({
    this.accounts = const [],
    this.jobs = const [],
    this.activeJobId,
    this.pendingConflicts = const [],
  });

  // ── Computed ──

  bool get hasAccounts => accounts.isNotEmpty;
  bool get hasJobs => jobs.isNotEmpty;
  int get activeJobCount => jobs.where((j) => j.isActive).length;

  ServerSyncJob? get selectedJob =>
      activeJobId != null ? jobById(activeJobId!) : null;

  SyncAccount? accountById(String id) {
    for (final a in accounts) {
      if (a.id == id) return a;
    }
    return null;
  }

  ServerSyncJob? jobById(String id) {
    for (final j in jobs) {
      if (j.id == id) return j;
    }
    return null;
  }

  /// Get all jobs that reference a given account (by serverId field).
  List<ServerSyncJob> jobsForAccount(String accountId) =>
      jobs.where((j) => j.serverId == accountId).toList();

  // ── Backward compatibility aliases ──

  /// @deprecated Use [accounts] instead.
  List<SyncAccount> get servers => accounts;

  /// @deprecated Use [hasAccounts] instead.
  bool get hasServers => hasAccounts;

  /// @deprecated Use [accountById] instead.
  SyncAccount? serverById(String id) => accountById(id);

  /// @deprecated Use [jobsForAccount] instead.
  List<ServerSyncJob> jobsForServer(String serverId) =>
      jobsForAccount(serverId);

  // ── Copy ──

  ServerSyncState copyWith({
    List<SyncAccount>? accounts,
    List<ServerSyncJob>? jobs,
    String? activeJobId,
    bool clearActiveJobId = false,
    List<SyncConflict>? pendingConflicts,
  }) =>
      ServerSyncState(
        accounts: accounts ?? this.accounts,
        jobs: jobs ?? this.jobs,
        activeJobId:
            clearActiveJobId ? null : (activeJobId ?? this.activeJobId),
        pendingConflicts: pendingConflicts ?? this.pendingConflicts,
      );
}
