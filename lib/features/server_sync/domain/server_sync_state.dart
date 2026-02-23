import 'package:anyware/features/server_sync/domain/sftp_server_config.dart';
import 'package:anyware/features/server_sync/domain/server_sync_job.dart';
import 'package:anyware/features/sync/domain/sync_state.dart';

/// Top-level state for the Server Sync feature.
class ServerSyncState {
  final List<SftpServerConfig> servers;
  final List<ServerSyncJob> jobs;
  final String? activeJobId;
  final List<SyncConflict> pendingConflicts;

  const ServerSyncState({
    this.servers = const [],
    this.jobs = const [],
    this.activeJobId,
    this.pendingConflicts = const [],
  });

  // ── Computed ──

  bool get hasServers => servers.isNotEmpty;
  bool get hasJobs => jobs.isNotEmpty;
  int get activeJobCount => jobs.where((j) => j.isActive).length;

  ServerSyncJob? get selectedJob =>
      activeJobId != null ? jobById(activeJobId!) : null;

  SftpServerConfig? serverById(String id) {
    for (final s in servers) {
      if (s.id == id) return s;
    }
    return null;
  }

  ServerSyncJob? jobById(String id) {
    for (final j in jobs) {
      if (j.id == id) return j;
    }
    return null;
  }

  List<ServerSyncJob> jobsForServer(String serverId) =>
      jobs.where((j) => j.serverId == serverId).toList();

  // ── Copy ──

  ServerSyncState copyWith({
    List<SftpServerConfig>? servers,
    List<ServerSyncJob>? jobs,
    String? activeJobId,
    bool clearActiveJobId = false,
    List<SyncConflict>? pendingConflicts,
  }) =>
      ServerSyncState(
        servers: servers ?? this.servers,
        jobs: jobs ?? this.jobs,
        activeJobId:
            clearActiveJobId ? null : (activeJobId ?? this.activeJobId),
        pendingConflicts: pendingConflicts ?? this.pendingConflicts,
      );
}
