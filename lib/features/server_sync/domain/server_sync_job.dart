import 'package:anyware/features/server_sync/domain/sync_account.dart';
import 'package:anyware/features/sync/domain/sync_state.dart';

/// A sync job that synchronises a local folder with a remote provider.
///
/// Mirrors [SyncJob] but targets a [SyncAccount] (by [serverId])
/// instead of a LAN device. The [providerType] indicates whether this
/// job targets SFTP, Google Drive, or OneDrive.
class ServerSyncJob {
  final String id;
  final String name;
  final String sourceDirectory;

  /// References [SyncAccount.id].
  final String serverId;

  /// Cached account display name.
  final String serverName;

  /// The provider type of the referenced account.
  final SyncProviderType providerType;

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

  /// Index of the last successfully processed file in the current sync batch.
  /// Used for resuming a sync job after crash/restart. -1 means no checkpoint.
  final int lastProcessedIndex;

  const ServerSyncJob({
    required this.id,
    required this.name,
    required this.sourceDirectory,
    required this.serverId,
    this.serverName = '',
    this.providerType = SyncProviderType.sftp,
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
    this.lastProcessedIndex = -1,
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
    SyncProviderType? providerType,
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
    int? lastProcessedIndex,
  }) =>
      ServerSyncJob(
        id: id,
        name: name ?? this.name,
        sourceDirectory: sourceDirectory ?? this.sourceDirectory,
        serverId: serverId ?? this.serverId,
        serverName: serverName ?? this.serverName,
        providerType: providerType ?? this.providerType,
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
        lastProcessedIndex: lastProcessedIndex ?? this.lastProcessedIndex,
      );

  // ── JSON ──

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'sourceDirectory': sourceDirectory,
        'serverId': serverId,
        'serverName': serverName,
        'providerType': providerType.name,
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
        'lastProcessedIndex': lastProcessedIndex,
      };

  factory ServerSyncJob.fromJson(Map<String, dynamic> json) {
    return ServerSyncJob(
      id: json['id'] as String,
      name: json['name'] as String,
      sourceDirectory: json['sourceDirectory'] as String,
      serverId: json['serverId'] as String,
      serverName: (json['serverName'] as String?) ?? '',
      providerType: _providerFromName(json['providerType'] as String?),
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
      lastProcessedIndex: json['lastProcessedIndex'] as int? ?? -1,
    );
  }
}

T _enumFromName<T extends Enum>(List<T> values, String? name, T fallback) {
  if (name == null) return fallback;
  return values.firstWhere((v) => v.name == name, orElse: () => fallback);
}

SyncProviderType _providerFromName(String? name) {
  if (name == null) return SyncProviderType.sftp;
  return SyncProviderType.values.firstWhere(
    (v) => v.name == name,
    orElse: () => SyncProviderType.sftp,
  );
}
