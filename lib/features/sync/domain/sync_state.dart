import 'package:anyware/features/discovery/domain/device.dart';

class SyncState {
  final bool isSyncing;
  final String? sourceDirectory;
  final Device? targetDevice;
  final DateTime? lastSyncTime;
  final String? status;

  /// Number of successfully synced files in the last batch.
  final int syncedCount;

  /// Number of failed files in the last batch.
  final int failedCount;

  /// List of files that failed to sync with error messages.
  final List<SyncError> failedFiles;

  const SyncState({
    this.isSyncing = false,
    this.sourceDirectory,
    this.targetDevice,
    this.lastSyncTime,
    this.status,
    this.syncedCount = 0,
    this.failedCount = 0,
    this.failedFiles = const [],
  });

  SyncState copyWith({
    bool? isSyncing,
    String? sourceDirectory,
    Device? targetDevice,
    DateTime? lastSyncTime,
    String? status,
    int? syncedCount,
    int? failedCount,
    List<SyncError>? failedFiles,
  }) {
    return SyncState(
      isSyncing: isSyncing ?? this.isSyncing,
      sourceDirectory: sourceDirectory ?? this.sourceDirectory,
      targetDevice: targetDevice ?? this.targetDevice,
      lastSyncTime: lastSyncTime ?? this.lastSyncTime,
      status: status ?? this.status,
      syncedCount: syncedCount ?? this.syncedCount,
      failedCount: failedCount ?? this.failedCount,
      failedFiles: failedFiles ?? this.failedFiles,
    );
  }

  /// Whether the last sync had any failures.
  bool get hasErrors => failedCount > 0;
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
