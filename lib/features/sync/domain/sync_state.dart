import 'package:flutter/material.dart';

// ═══════════════════════════════════════════════════════════════════════════════
// Enums
// ═══════════════════════════════════════════════════════════════════════════════

/// Status of a single file in a sync operation.
enum SyncFileStatus { pending, syncing, completed, failed, paused, skipped }

/// Phase of a sync job lifecycle.
enum SyncJobPhase {
  /// Job exists but is not running.
  idle,

  /// Actively scanning / sending / receiving files.
  syncing,

  /// Initial batch done; watcher is monitoring for changes.
  watching,

  /// An error occurred (e.g. connection lost). May auto-recover.
  error,

  /// User paused this job.
  paused,
}

/// Type of sync schedule.
enum ScheduleType { daily, weekly, interval }

/// Direction of sync.
enum SyncDirection {
  /// One-way push: source → target (backup style).
  oneWay,

  /// Bidirectional: changes on either side are synced to the other.
  bidirectional,
}

/// Strategy for resolving file conflicts (both sides changed since last sync).
enum ConflictStrategy {
  /// The file with the newer modification date wins.
  newerWins,

  /// Show a prompt and let the user decide per file.
  askUser,

  /// Keep both files — rename the older one with a _conflict suffix.
  keepBoth,
}

/// Sync mode — determines special handling.
enum SyncMode {
  /// Sync any folder as-is.
  general,

  /// Photo/video optimised: DCIM detection, date subfolders, HEIC→JPG.
  photoVideo,
}

// ═══════════════════════════════════════════════════════════════════════════════
// Support classes
// ═══════════════════════════════════════════════════════════════════════════════

/// Represents a single file being tracked during sync.
class SyncFileItem {
  final String relativePath;
  final SyncFileStatus status;
  final String? error;
  final DateTime? completedAt;
  final int fileSize;

  const SyncFileItem({
    required this.relativePath,
    required this.status,
    this.error,
    this.completedAt,
    this.fileSize = 0,
  });

  SyncFileItem copyWith({
    SyncFileStatus? status,
    String? error,
    DateTime? completedAt,
    int? fileSize,
  }) =>
      SyncFileItem(
        relativePath: relativePath,
        status: status ?? this.status,
        error: error ?? this.error,
        completedAt: completedAt ?? this.completedAt,
        fileSize: fileSize ?? this.fileSize,
      );
}

/// Represents a single file sync failure.
class SyncError {
  final String filePath;
  final String error;
  final DateTime timestamp;

  const SyncError({
    required this.filePath,
    required this.error,
    required this.timestamp,
  });
}

/// Represents a file conflict that needs resolution.
class SyncConflict {
  final String relativePath;
  final int localSize;
  final DateTime localModified;
  final int remoteSize;
  final DateTime remoteModified;

  /// `null` = unresolved, `'local'`, `'remote'`, `'both'`.
  final String? resolution;

  const SyncConflict({
    required this.relativePath,
    required this.localSize,
    required this.localModified,
    required this.remoteSize,
    required this.remoteModified,
    this.resolution,
  });

  SyncConflict copyWith({String? resolution}) => SyncConflict(
        relativePath: relativePath,
        localSize: localSize,
        localModified: localModified,
        remoteSize: remoteSize,
        remoteModified: remoteModified,
        resolution: resolution ?? this.resolution,
      );

  bool get isResolved => resolution != null;
}

/// Tracks an incoming sync session from a remote device (receiver side).
///
/// When [jobId] is non-null, this session belongs to a specific sync job
/// on the sender side (job-aware protocol). Files are stored in a per-job
/// subfolder: `<SyncFolder>/<senderName>/<jobName>/`.
class ReceiverSyncSession {
  final String senderDeviceId;
  final String senderName;
  final DateTime startedAt;
  final List<SyncFileItem> receivedItems;
  final int totalExpectedFiles;
  final int totalExpectedBytes;
  final int receivedBytes;
  final bool isActive;

  /// Sender-side sync job UUID — links this session to a specific job.
  final String? jobId;

  /// Sender-side sync job display name (e.g. "Belgeler", "Photos").
  final String? jobName;

  const ReceiverSyncSession({
    required this.senderDeviceId,
    required this.senderName,
    required this.startedAt,
    this.receivedItems = const [],
    this.totalExpectedFiles = 0,
    this.totalExpectedBytes = 0,
    this.receivedBytes = 0,
    this.isActive = true,
    this.jobId,
    this.jobName,
  });

  double get progress =>
      totalExpectedBytes > 0
          ? (receivedBytes / totalExpectedBytes).clamp(0.0, 1.0)
          : 0.0;

  ReceiverSyncSession copyWith({
    List<SyncFileItem>? receivedItems,
    int? totalExpectedFiles,
    int? totalExpectedBytes,
    int? receivedBytes,
    bool? isActive,
    String? jobId,
    String? jobName,
  }) =>
      ReceiverSyncSession(
        senderDeviceId: senderDeviceId,
        senderName: senderName,
        startedAt: startedAt,
        receivedItems: receivedItems ?? this.receivedItems,
        totalExpectedFiles: totalExpectedFiles ?? this.totalExpectedFiles,
        totalExpectedBytes: totalExpectedBytes ?? this.totalExpectedBytes,
        receivedBytes: receivedBytes ?? this.receivedBytes,
        isActive: isActive ?? this.isActive,
        jobId: jobId ?? this.jobId,
        jobName: jobName ?? this.jobName,
      );
}

/// Configuration for automatic sync scheduling.
class SyncSchedule {
  final ScheduleType type;
  final TimeOfDay? time;
  final List<int> weekDays; // 1=Monday ... 7=Sunday
  final Duration? interval;
  final bool enabled;

  const SyncSchedule({
    required this.type,
    this.time,
    this.weekDays = const [],
    this.interval,
    this.enabled = true,
  });

  SyncSchedule copyWith({
    ScheduleType? type,
    TimeOfDay? time,
    List<int>? weekDays,
    Duration? interval,
    bool? enabled,
  }) =>
      SyncSchedule(
        type: type ?? this.type,
        time: time ?? this.time,
        weekDays: weekDays ?? this.weekDays,
        interval: interval ?? this.interval,
        enabled: enabled ?? this.enabled,
      );

  Map<String, dynamic> toJson() => {
        'type': type.name,
        'timeHour': time?.hour,
        'timeMinute': time?.minute,
        'weekDays': weekDays,
        'intervalMinutes': interval?.inMinutes,
        'enabled': enabled,
      };

  factory SyncSchedule.fromJson(Map<String, dynamic> json) {
    return SyncSchedule(
      type: ScheduleType.values.firstWhere(
        (t) => t.name == json['type'],
        orElse: () => ScheduleType.interval,
      ),
      time: json['timeHour'] != null
          ? TimeOfDay(
              hour: json['timeHour'] as int,
              minute: (json['timeMinute'] as int?) ?? 0,
            )
          : null,
      weekDays: (json['weekDays'] as List<dynamic>?)
              ?.map((e) => e as int)
              .toList() ??
          [],
      interval: json['intervalMinutes'] != null
          ? Duration(minutes: json['intervalMinutes'] as int)
          : null,
      enabled: json['enabled'] as bool? ?? true,
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// SyncJob — one independent sync task (folder ↔ device)
// ═══════════════════════════════════════════════════════════════════════════════

class SyncJob {
  /// Unique identifier (UUID).
  final String id;

  /// User-facing label, e.g. "Documents → Laptop".
  final String name;

  /// Absolute path of the source folder.
  final String sourceDirectory;

  /// Target device ID (from discovery).
  final String targetDeviceId;

  /// Cached target device display name.
  final String targetDeviceName;

  /// Cached target device IP.
  final String? targetDeviceIp;

  /// Current lifecycle phase.
  final SyncJobPhase phase;

  /// Optional schedule for automatic sync.
  final SyncSchedule? schedule;

  /// When this job was created.
  final DateTime createdAt;

  /// Last time a successful sync batch completed.
  final DateTime? lastSyncTime;

  // ── Sync configuration ──

  /// Direction of sync: one-way or bidirectional.
  final SyncDirection syncDirection;

  /// How to handle conflicts (only meaningful for bidirectional).
  final ConflictStrategy conflictStrategy;

  /// General folder sync or photo/video optimised.
  final SyncMode syncMode;

  /// Glob patterns to include (empty = include all).
  final List<String> includePatterns;

  /// Glob patterns to exclude.
  final List<String> excludePatterns;

  /// Whether deleting a file on source should also delete it on target.
  final bool mirrorDeletions;

  /// Optional custom destination folder on the target device.
  final String? remoteBaseDir;

  // ── Pairing / resume state ──

  /// Whether the receiver has accepted this job's pairing.
  /// When `true`, [startJob] skips the setup request handshake.
  final bool acceptedByReceiver;

  /// Whether this job was actively running (watching/syncing) before the app
  /// was closed. When `true`, the job is automatically resumed on app startup.
  final bool wasRunning;

  // ── Photo/video mode options ──

  /// Convert HEIC/HEIF images to JPG before sending.
  final bool convertHeicToJpg;

  /// Date-based subfolder format (e.g. 'YYYY/MM' or 'YYYY-MM-DD').
  final String dateSubfolderFormat;

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

  const SyncJob({
    required this.id,
    required this.name,
    required this.sourceDirectory,
    required this.targetDeviceId,
    this.targetDeviceName = '',
    this.targetDeviceIp,
    this.phase = SyncJobPhase.idle,
    this.schedule,
    required this.createdAt,
    this.lastSyncTime,
    // Sync config — defaults make v2 → v3 migration transparent.
    this.syncDirection = SyncDirection.oneWay,
    this.conflictStrategy = ConflictStrategy.newerWins,
    this.syncMode = SyncMode.general,
    this.includePatterns = const [],
    this.excludePatterns = const [],
    this.mirrorDeletions = true,
    this.remoteBaseDir,
    this.acceptedByReceiver = false,
    this.wasRunning = false,
    this.convertHeicToJpg = false,
    this.dateSubfolderFormat = 'YYYY/MM',
    // Progress state.
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
  bool get isPhotoMode => syncMode == SyncMode.photoVideo;

  double get progress =>
      totalBytes > 0 ? (transferredBytes / totalBytes).clamp(0.0, 1.0) : 0.0;

  String get progressPercent => '${(progress * 100).toInt()}%';

  /// Descriptive sync direction arrow.
  String get directionArrow =>
      syncDirection == SyncDirection.bidirectional ? '↔' : '→';

  // ── Copy ──

  SyncJob copyWith({
    String? name,
    String? sourceDirectory,
    String? targetDeviceId,
    String? targetDeviceName,
    String? targetDeviceIp,
    SyncJobPhase? phase,
    SyncSchedule? schedule,
    bool clearSchedule = false,
    DateTime? lastSyncTime,
    SyncDirection? syncDirection,
    ConflictStrategy? conflictStrategy,
    SyncMode? syncMode,
    List<String>? includePatterns,
    List<String>? excludePatterns,
    bool? mirrorDeletions,
    String? remoteBaseDir,
    bool clearRemoteBaseDir = false,
    bool? acceptedByReceiver,
    bool? wasRunning,
    bool? convertHeicToJpg,
    String? dateSubfolderFormat,
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
      SyncJob(
        id: id,
        name: name ?? this.name,
        sourceDirectory: sourceDirectory ?? this.sourceDirectory,
        targetDeviceId: targetDeviceId ?? this.targetDeviceId,
        targetDeviceName: targetDeviceName ?? this.targetDeviceName,
        targetDeviceIp: targetDeviceIp ?? this.targetDeviceIp,
        phase: phase ?? this.phase,
        schedule: clearSchedule ? null : (schedule ?? this.schedule),
        createdAt: createdAt,
        lastSyncTime: lastSyncTime ?? this.lastSyncTime,
        syncDirection: syncDirection ?? this.syncDirection,
        conflictStrategy: conflictStrategy ?? this.conflictStrategy,
        syncMode: syncMode ?? this.syncMode,
        includePatterns: includePatterns ?? this.includePatterns,
        excludePatterns: excludePatterns ?? this.excludePatterns,
        mirrorDeletions: mirrorDeletions ?? this.mirrorDeletions,
        remoteBaseDir:
            clearRemoteBaseDir ? null : (remoteBaseDir ?? this.remoteBaseDir),
        acceptedByReceiver: acceptedByReceiver ?? this.acceptedByReceiver,
        wasRunning: wasRunning ?? this.wasRunning,
        convertHeicToJpg: convertHeicToJpg ?? this.convertHeicToJpg,
        dateSubfolderFormat:
            dateSubfolderFormat ?? this.dateSubfolderFormat,
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

  // ── JSON (for SharedPreferences persistence) ──
  // v3 format — backward compatible: missing keys use default values.

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'sourceDirectory': sourceDirectory,
        'targetDeviceId': targetDeviceId,
        'targetDeviceName': targetDeviceName,
        'targetDeviceIp': targetDeviceIp,
        'createdAt': createdAt.toIso8601String(),
        'lastSyncTime': lastSyncTime?.toIso8601String(),
        if (schedule != null) 'schedule': schedule!.toJson(),
        // v3 fields
        'syncDirection': syncDirection.name,
        'conflictStrategy': conflictStrategy.name,
        'syncMode': syncMode.name,
        'includePatterns': includePatterns,
        'excludePatterns': excludePatterns,
        'mirrorDeletions': mirrorDeletions,
        'remoteBaseDir': remoteBaseDir,
        'acceptedByReceiver': acceptedByReceiver,
        'wasRunning': wasRunning,
        'convertHeicToJpg': convertHeicToJpg,
        'dateSubfolderFormat': dateSubfolderFormat,
        'lastProcessedIndex': lastProcessedIndex,
      };

  factory SyncJob.fromJson(Map<String, dynamic> json) {
    return SyncJob(
      id: json['id'] as String,
      name: json['name'] as String,
      sourceDirectory: json['sourceDirectory'] as String,
      targetDeviceId: json['targetDeviceId'] as String,
      targetDeviceName: (json['targetDeviceName'] as String?) ?? '',
      targetDeviceIp: json['targetDeviceIp'] as String?,
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
      lastSyncTime: json['lastSyncTime'] != null
          ? DateTime.tryParse(json['lastSyncTime'] as String)
          : null,
      schedule: json['schedule'] != null
          ? SyncSchedule.fromJson(json['schedule'] as Map<String, dynamic>)
          : null,
      // v3 fields — defaults handle backward compatibility with v2 data.
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
      syncMode: _enumFromName(
        SyncMode.values,
        json['syncMode'] as String?,
        SyncMode.general,
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
      remoteBaseDir: json['remoteBaseDir'] as String?,
      acceptedByReceiver: json['acceptedByReceiver'] as bool? ?? false,
      wasRunning: json['wasRunning'] as bool? ?? false,
      convertHeicToJpg: json['convertHeicToJpg'] as bool? ?? false,
      dateSubfolderFormat:
          json['dateSubfolderFormat'] as String? ?? 'YYYY/MM',
      lastProcessedIndex: json['lastProcessedIndex'] as int? ?? -1,
    );
  }
}

/// Safe enum deserialization helper — returns [fallback] if [name] is null or
/// doesn't match any value.
T _enumFromName<T extends Enum>(List<T> values, String? name, T fallback) {
  if (name == null) return fallback;
  return values.firstWhere(
    (v) => v.name == name,
    orElse: () => fallback,
  );
}

// ═══════════════════════════════════════════════════════════════════════════════
// SyncPairing — persistent receiver-side pairing (accepted sync setup)
// ═══════════════════════════════════════════════════════════════════════════════

/// Represents an accepted sync pairing on the receiver side.
///
/// When a sender sends a setup request and the receiver accepts, a
/// [SyncPairing] is created and persisted. Future sync requests with the
/// same [jobId] are automatically accepted without showing the dialog again.
class SyncPairing {
  /// The shared sync job UUID — same on both sender and receiver.
  final String jobId;

  /// Human-readable name of the sync job (e.g. "Belgeler").
  final String jobName;

  /// Device ID of the paired sender.
  final String senderDeviceId;

  /// Display name of the paired sender device.
  final String senderDeviceName;

  /// The local folder where received files are stored.
  final String receiveFolder;

  /// The sync direction (oneWay or bidirectional).
  final SyncDirection direction;

  /// When this pairing was accepted.
  final DateTime acceptedAt;

  /// Whether this pairing is currently active.
  final bool isActive;

  /// Last successful sync completion time.
  final DateTime? lastSyncTime;

  /// Number of files in the most recent sync.
  final int lastSyncFileCount;

  /// Total bytes transferred in the most recent sync.
  final int lastSyncTotalBytes;

  const SyncPairing({
    required this.jobId,
    required this.jobName,
    required this.senderDeviceId,
    required this.senderDeviceName,
    required this.receiveFolder,
    required this.direction,
    required this.acceptedAt,
    this.isActive = true,
    this.lastSyncTime,
    this.lastSyncFileCount = 0,
    this.lastSyncTotalBytes = 0,
  });

  SyncPairing copyWith({
    String? jobName,
    String? senderDeviceName,
    String? receiveFolder,
    SyncDirection? direction,
    bool? isActive,
    DateTime? lastSyncTime,
    int? lastSyncFileCount,
    int? lastSyncTotalBytes,
  }) =>
      SyncPairing(
        jobId: jobId,
        jobName: jobName ?? this.jobName,
        senderDeviceId: senderDeviceId,
        senderDeviceName: senderDeviceName ?? this.senderDeviceName,
        receiveFolder: receiveFolder ?? this.receiveFolder,
        direction: direction ?? this.direction,
        acceptedAt: acceptedAt,
        isActive: isActive ?? this.isActive,
        lastSyncTime: lastSyncTime ?? this.lastSyncTime,
        lastSyncFileCount: lastSyncFileCount ?? this.lastSyncFileCount,
        lastSyncTotalBytes: lastSyncTotalBytes ?? this.lastSyncTotalBytes,
      );

  Map<String, dynamic> toJson() => {
        'jobId': jobId,
        'jobName': jobName,
        'senderDeviceId': senderDeviceId,
        'senderDeviceName': senderDeviceName,
        'receiveFolder': receiveFolder,
        'direction': direction.name,
        'acceptedAt': acceptedAt.toIso8601String(),
        'isActive': isActive,
        if (lastSyncTime != null)
          'lastSyncTime': lastSyncTime!.toIso8601String(),
        'lastSyncFileCount': lastSyncFileCount,
        'lastSyncTotalBytes': lastSyncTotalBytes,
      };

  factory SyncPairing.fromJson(Map<String, dynamic> json) => SyncPairing(
        jobId: json['jobId'] as String,
        jobName: json['jobName'] as String? ?? '',
        senderDeviceId: json['senderDeviceId'] as String,
        senderDeviceName: json['senderDeviceName'] as String? ?? '',
        receiveFolder: json['receiveFolder'] as String,
        direction: SyncDirection.values.firstWhere(
          (d) => d.name == json['direction'],
          orElse: () => SyncDirection.oneWay,
        ),
        acceptedAt: DateTime.tryParse(json['acceptedAt'] as String? ?? '') ??
            DateTime.now(),
        isActive: json['isActive'] as bool? ?? true,
        lastSyncTime: json['lastSyncTime'] != null
            ? DateTime.tryParse(json['lastSyncTime'] as String)
            : null,
        lastSyncFileCount: json['lastSyncFileCount'] as int? ?? 0,
        lastSyncTotalBytes: json['lastSyncTotalBytes'] as int? ?? 0,
      );
}

// ═══════════════════════════════════════════════════════════════════════════════
// SyncSetupRequest — incoming setup request from a sender device
// ═══════════════════════════════════════════════════════════════════════════════

/// Data object representing a sync setup request received from a remote device.
///
/// The receiver shows a dialog with this information and lets the user choose
/// a target folder before accepting or rejecting.
class SyncSetupRequest {
  final String jobId;
  final String jobName;
  final String senderDeviceId;
  final String senderDeviceName;
  final String senderIp;
  final SyncDirection direction;
  final int fileCount;
  final int totalSize;

  /// The absolute path on the RECEIVER device that the sender selected via
  /// the remote folder browser.  When present the receiver can auto-accept
  /// without showing a dialog because the sender already chose the folder.
  final String? remoteBaseDir;

  const SyncSetupRequest({
    required this.jobId,
    required this.jobName,
    required this.senderDeviceId,
    required this.senderDeviceName,
    required this.senderIp,
    required this.direction,
    this.fileCount = 0,
    this.totalSize = 0,
    this.remoteBaseDir,
  });

  factory SyncSetupRequest.fromJson(Map<String, dynamic> json) =>
      SyncSetupRequest(
        jobId: json['jobId'] as String? ?? '',
        jobName: json['jobName'] as String? ?? '',
        senderDeviceId: json['senderDeviceId'] as String? ?? '',
        senderDeviceName: json['senderDeviceName'] as String? ?? '',
        senderIp: json['senderIp'] as String? ?? '',
        direction: SyncDirection.values.firstWhere(
          (d) => d.name == (json['direction'] as String? ?? ''),
          orElse: () => SyncDirection.oneWay,
        ),
        fileCount: json['fileCount'] as int? ?? 0,
        totalSize: json['totalSize'] as int? ?? 0,
        remoteBaseDir: json['remoteBaseDir'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'jobId': jobId,
        'jobName': jobName,
        'senderDeviceId': senderDeviceId,
        'senderDeviceName': senderDeviceName,
        'senderIp': senderIp,
        'direction': direction.name,
        'fileCount': fileCount,
        'totalSize': totalSize,
        if (remoteBaseDir != null) 'remoteBaseDir': remoteBaseDir,
      };
}

// ═══════════════════════════════════════════════════════════════════════════════
// SyncState — top-level state for the sync feature
// ═══════════════════════════════════════════════════════════════════════════════

class SyncState {
  /// All registered sync jobs.
  final List<SyncJob> jobs;

  /// ID of the currently viewed job in the detail screen (UI navigation only).
  final String? activeJobId;

  // ── Receiver side (incoming files from other devices) ──
  final bool isReceiving;
  final String? receiverSenderName;
  final List<SyncFileItem> receivedItems;

  /// Active incoming sync sessions, keyed by sender device ID.
  final Map<String, ReceiverSyncSession> activeSyncSessions;

  /// Pending conflicts awaiting user resolution (for askUser strategy).
  final List<SyncConflict> pendingConflicts;

  // ── Pairing (sync handshake) ──

  /// Accepted sync pairings — persistent receiver-side data.
  final List<SyncPairing> pairings;

  /// A pending sync setup request waiting for user accept/reject.
  /// When non-null the UI should show the setup dialog.
  final SyncSetupRequest? pendingSyncSetup;

  const SyncState({
    this.jobs = const [],
    this.activeJobId,
    this.isReceiving = false,
    this.receiverSenderName,
    this.receivedItems = const [],
    this.activeSyncSessions = const {},
    this.pendingConflicts = const [],
    this.pairings = const [],
    this.pendingSyncSetup,
  });

  // ── Computed ──

  /// Whether any job is currently active (syncing, watching, or paused).
  bool get hasActiveJobs => jobs.any((j) => j.isActive);

  /// Number of currently active jobs.
  int get activeJobCount => jobs.where((j) => j.isActive).length;

  /// The job currently being viewed in the detail screen.
  SyncJob? get selectedJob {
    if (activeJobId == null) return null;
    final idx = jobs.indexWhere((j) => j.id == activeJobId);
    return idx >= 0 ? jobs[idx] : null;
  }

  /// Whether any job is actively syncing (sending/receiving files right now).
  bool get isSyncing => jobs.any((j) => j.phase == SyncJobPhase.syncing);

  /// Whether there are unresolved conflicts waiting for the user.
  bool get hasConflicts => pendingConflicts.any((c) => !c.isResolved);

  /// Number of active incoming sync sessions.
  int get activeSessionCount =>
      activeSyncSessions.values.where((s) => s.isActive).length;

  // ── Copy ──

  SyncState copyWith({
    List<SyncJob>? jobs,
    String? activeJobId,
    bool clearActiveJobId = false,
    bool? isReceiving,
    String? receiverSenderName,
    List<SyncFileItem>? receivedItems,
    Map<String, ReceiverSyncSession>? activeSyncSessions,
    List<SyncConflict>? pendingConflicts,
    List<SyncPairing>? pairings,
    SyncSetupRequest? pendingSyncSetup,
    bool clearPendingSyncSetup = false,
  }) =>
      SyncState(
        jobs: jobs ?? this.jobs,
        activeJobId: clearActiveJobId ? null : (activeJobId ?? this.activeJobId),
        isReceiving: isReceiving ?? this.isReceiving,
        receiverSenderName: receiverSenderName ?? this.receiverSenderName,
        receivedItems: receivedItems ?? this.receivedItems,
        activeSyncSessions: activeSyncSessions ?? this.activeSyncSessions,
        pendingConflicts: pendingConflicts ?? this.pendingConflicts,
        pairings: pairings ?? this.pairings,
        pendingSyncSetup: clearPendingSyncSetup
            ? null
            : (pendingSyncSetup ?? this.pendingSyncSetup),
      );

  // ── Job helpers ──

  /// Returns a new [SyncState] with the given [job] updated in the jobs list.
  /// If no job with the same ID exists the state is returned unchanged.
  SyncState updateJob(SyncJob job) {
    final idx = jobs.indexWhere((j) => j.id == job.id);
    if (idx < 0) return this;
    final updated = List<SyncJob>.from(jobs);
    updated[idx] = job;
    return copyWith(jobs: updated);
  }

  /// Returns a new [SyncState] with the given [job] added.
  SyncState addJob(SyncJob job) => copyWith(jobs: [...jobs, job]);

  /// Returns a new [SyncState] with the job having [jobId] removed.
  SyncState removeJob(String jobId) =>
      copyWith(jobs: jobs.where((j) => j.id != jobId).toList());

  // ── Pairing helpers ──

  /// Finds a pairing by its shared job ID. Returns `null` if not found.
  SyncPairing? findPairing(String jobId) {
    final idx = pairings.indexWhere((p) => p.jobId == jobId);
    return idx >= 0 ? pairings[idx] : null;
  }

  /// Returns a new [SyncState] with the given [pairing] added.
  /// If a pairing with the same [jobId] already exists it is replaced.
  SyncState addPairing(SyncPairing pairing) {
    final updated = pairings.where((p) => p.jobId != pairing.jobId).toList();
    updated.add(pairing);
    return copyWith(pairings: updated);
  }

  /// Returns a new [SyncState] with the pairing having [jobId] removed.
  SyncState removePairing(String jobId) =>
      copyWith(pairings: pairings.where((p) => p.jobId != jobId).toList());

  /// Returns a new [SyncState] with the given [pairing] updated in the list.
  SyncState updatePairing(SyncPairing pairing) {
    final idx = pairings.indexWhere((p) => p.jobId == pairing.jobId);
    if (idx < 0) return this;
    final updated = List<SyncPairing>.from(pairings);
    updated[idx] = pairing;
    return copyWith(pairings: updated);
  }
}
