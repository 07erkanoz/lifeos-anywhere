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

  /// User-facing label, e.g. "Dökümanlar → Laptop".
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

  // ── Active sync progress ──

  final String? status;
  final List<SyncFileItem> fileItems;
  final int totalBytes;
  final int transferredBytes;
  final DateTime? syncStartTime;
  final int syncedCount;
  final int failedCount;
  final List<SyncError> failedFiles;

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

  double get progress =>
      totalBytes > 0 ? (transferredBytes / totalBytes).clamp(0.0, 1.0) : 0.0;

  String get progressPercent => '${(progress * 100).toInt()}%';

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
    String? status,
    List<SyncFileItem>? fileItems,
    int? totalBytes,
    int? transferredBytes,
    DateTime? syncStartTime,
    int? syncedCount,
    int? failedCount,
    List<SyncError>? failedFiles,
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
        status: status ?? this.status,
        fileItems: fileItems ?? this.fileItems,
        totalBytes: totalBytes ?? this.totalBytes,
        transferredBytes: transferredBytes ?? this.transferredBytes,
        syncStartTime: syncStartTime ?? this.syncStartTime,
        syncedCount: syncedCount ?? this.syncedCount,
        failedCount: failedCount ?? this.failedCount,
        failedFiles: failedFiles ?? this.failedFiles,
      );

  // ── JSON (for SharedPreferences persistence) ──

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
    );
  }
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

  const SyncState({
    this.jobs = const [],
    this.activeJobId,
    this.isReceiving = false,
    this.receiverSenderName,
    this.receivedItems = const [],
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

  // ── Copy ──

  SyncState copyWith({
    List<SyncJob>? jobs,
    String? activeJobId,
    bool clearActiveJobId = false,
    bool? isReceiving,
    String? receiverSenderName,
    List<SyncFileItem>? receivedItems,
  }) =>
      SyncState(
        jobs: jobs ?? this.jobs,
        activeJobId: clearActiveJobId ? null : (activeJobId ?? this.activeJobId),
        isReceiving: isReceiving ?? this.isReceiving,
        receiverSenderName: receiverSenderName ?? this.receiverSenderName,
        receivedItems: receivedItems ?? this.receivedItems,
      );

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
}
