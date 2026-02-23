import 'package:anyware/features/sync/domain/sync_state.dart';

/// A sync job that synchronises a local folder with an SFTP server.
///
/// Mirrors [SyncJob] but targets an [SftpServerConfig] (by [serverId])
/// instead of a LAN device.
class ServerSyncJob {
  final String id;
  final String name;
  final String sourceDirectory;

  /// References [SftpServerConfig.id].
  final String serverId;

  /// Cached server display name.
  final String serverName;

  /// Optional subfolder appended to the server's [remotePath].
  final String remoteSubPath;

  final SyncJobPhase phase;
  final SyncSchedule? schedule;
  final DateTime createdAt;
  final DateTime? lastSyncTime;

  // ── Sync configuration ──
  final SyncDirection syncDirection;
  final ConflictStrategy conflictStrategy;
  final List<String> includePatterns;
  final List<String> excludePatterns;
  final bool mirrorDeletions;

  /// When `true`, a [DirectoryWatcher] monitors [sourceDirectory] and
  /// automatically pushes changed files to the server with debounce.
  final bool liveWatch;

  /// Whether this job was actively running before the app was closed.
  final bool wasRunning;

  // ── Active sync progress ──
  final String? status;
  final List<SyncFileItem> fileItems;
  final int totalBytes;
  final int transferredBytes;
  final DateTime? syncStartTime;
  final int syncedCount;
  final int failedCount;
  final List<SyncError> failedFiles;

  const ServerSyncJob({
    required this.id,
    required this.name,
    required this.sourceDirectory,
    required this.serverId,
    this.serverName = '',
    this.remoteSubPath = '',
    this.phase = SyncJobPhase.idle,
    this.schedule,
    required this.createdAt,
    this.lastSyncTime,
    this.syncDirection = SyncDirection.oneWay,
    this.conflictStrategy = ConflictStrategy.newerWins,
    this.includePatterns = const [],
    this.excludePatterns = const [],
    this.mirrorDeletions = true,
    this.liveWatch = false,
    this.wasRunning = false,
    this.status,
    this.fileItems = const [],
    this.totalBytes = 0,
    this.transferredBytes = 0,
    this.syncStartTime,
    this.syncedCount = 0,
    this.failedCount = 0,
    this.failedFiles = const [],
  });

  // ── Computed ──

  bool get isActive => phase != SyncJobPhase.idle;
  bool get hasErrors => failedCount > 0;
  bool get isBidirectional => syncDirection == SyncDirection.bidirectional;

  double get progress =>
      totalBytes > 0 ? (transferredBytes / totalBytes).clamp(0.0, 1.0) : 0.0;

  String get progressPercent => '${(progress * 100).toInt()}%';

  String get directionArrow =>
      syncDirection == SyncDirection.bidirectional ? '↔' : '→';

  // ── Copy ──

  ServerSyncJob copyWith({
    String? name,
    String? sourceDirectory,
    String? serverId,
    String? serverName,
    String? remoteSubPath,
    SyncJobPhase? phase,
    SyncSchedule? schedule,
    bool clearSchedule = false,
    DateTime? lastSyncTime,
    SyncDirection? syncDirection,
    ConflictStrategy? conflictStrategy,
    List<String>? includePatterns,
    List<String>? excludePatterns,
    bool? mirrorDeletions,
    bool? liveWatch,
    bool? wasRunning,
    String? status,
    List<SyncFileItem>? fileItems,
    int? totalBytes,
    int? transferredBytes,
    DateTime? syncStartTime,
    int? syncedCount,
    int? failedCount,
    List<SyncError>? failedFiles,
  }) =>
      ServerSyncJob(
        id: id,
        name: name ?? this.name,
        sourceDirectory: sourceDirectory ?? this.sourceDirectory,
        serverId: serverId ?? this.serverId,
        serverName: serverName ?? this.serverName,
        remoteSubPath: remoteSubPath ?? this.remoteSubPath,
        phase: phase ?? this.phase,
        schedule: clearSchedule ? null : (schedule ?? this.schedule),
        createdAt: createdAt,
        lastSyncTime: lastSyncTime ?? this.lastSyncTime,
        syncDirection: syncDirection ?? this.syncDirection,
        conflictStrategy: conflictStrategy ?? this.conflictStrategy,
        includePatterns: includePatterns ?? this.includePatterns,
        excludePatterns: excludePatterns ?? this.excludePatterns,
        mirrorDeletions: mirrorDeletions ?? this.mirrorDeletions,
        liveWatch: liveWatch ?? this.liveWatch,
        wasRunning: wasRunning ?? this.wasRunning,
        status: status ?? this.status,
        fileItems: fileItems ?? this.fileItems,
        totalBytes: totalBytes ?? this.totalBytes,
        transferredBytes: transferredBytes ?? this.transferredBytes,
        syncStartTime: syncStartTime ?? this.syncStartTime,
        syncedCount: syncedCount ?? this.syncedCount,
        failedCount: failedCount ?? this.failedCount,
        failedFiles: failedFiles ?? this.failedFiles,
      );

  // ── JSON ──

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'sourceDirectory': sourceDirectory,
        'serverId': serverId,
        'serverName': serverName,
        'remoteSubPath': remoteSubPath,
        'createdAt': createdAt.toIso8601String(),
        'lastSyncTime': lastSyncTime?.toIso8601String(),
        if (schedule != null) 'schedule': schedule!.toJson(),
        'syncDirection': syncDirection.name,
        'conflictStrategy': conflictStrategy.name,
        'includePatterns': includePatterns,
        'excludePatterns': excludePatterns,
        'mirrorDeletions': mirrorDeletions,
        'liveWatch': liveWatch,
        'wasRunning': wasRunning,
      };

  factory ServerSyncJob.fromJson(Map<String, dynamic> json) {
    return ServerSyncJob(
      id: json['id'] as String,
      name: json['name'] as String,
      sourceDirectory: json['sourceDirectory'] as String,
      serverId: json['serverId'] as String,
      serverName: (json['serverName'] as String?) ?? '',
      remoteSubPath: (json['remoteSubPath'] as String?) ?? '',
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
      lastSyncTime: json['lastSyncTime'] != null
          ? DateTime.tryParse(json['lastSyncTime'] as String)
          : null,
      schedule: json['schedule'] != null
          ? SyncSchedule.fromJson(json['schedule'] as Map<String, dynamic>)
          : null,
      syncDirection: _enumFromName(
        SyncDirection.values,
        json['syncDirection'] as String?,
        SyncDirection.oneWay,
      ),
      conflictStrategy: _enumFromName(
        ConflictStrategy.values,
        json['conflictStrategy'] as String?,
        ConflictStrategy.newerWins,
      ),
      includePatterns: (json['includePatterns'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList() ??
          const [],
      excludePatterns: (json['excludePatterns'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList() ??
          const [],
      mirrorDeletions: json['mirrorDeletions'] as bool? ?? true,
      liveWatch: json['liveWatch'] as bool? ?? false,
      wasRunning: json['wasRunning'] as bool? ?? false,
    );
  }
}

T _enumFromName<T extends Enum>(List<T> values, String? name, T fallback) {
  if (name == null) return fallback;
  return values.firstWhere((v) => v.name == name, orElse: () => fallback);
}
