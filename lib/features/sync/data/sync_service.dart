import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:anyware/core/logger.dart';
import 'package:flutter/material.dart' show TimeOfDay;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';
import 'package:watcher/watcher.dart';

import 'package:anyware/features/discovery/domain/device.dart';
import 'package:anyware/features/discovery/presentation/providers.dart';
import 'package:anyware/features/settings/data/settings_repository.dart';
import 'package:anyware/features/sync/domain/sync_state.dart';
import 'package:anyware/features/sync/data/sync_sender.dart';

// ═══════════════════════════════════════════════════════════════════════════════
// Provider
// ═══════════════════════════════════════════════════════════════════════════════

final syncServiceProvider =
    StateNotifierProvider<SyncService, SyncState>((ref) {
  return SyncService(ref);
});

// ═══════════════════════════════════════════════════════════════════════════════
// SyncService — multi-job sync manager
// ═══════════════════════════════════════════════════════════════════════════════

class SyncService extends StateNotifier<SyncState> {
  SyncService(this.ref) : super(const SyncState()) {
    _loadSavedJobs();
  }

  static final _log = AppLogger('SyncService');
  static const _uuid = Uuid();

  final Ref ref;

  /// Maximum retry attempts for failed sync files.
  static const int _maxRetries = 2;

  /// SharedPreferences key for persisted job list.
  static const _prefSyncJobs = 'sync_jobs_v2';

  // ─── Per-job runtime state (not serialised) ───
  final Map<String, StreamSubscription<WatchEvent>> _watchers = {};
  final Map<String, Timer?> _debounceTimers = {};
  final Map<String, Timer?> _scheduleTimers = {};
  final Map<String, Set<String>> _pendingFiles = {};
  final Map<String, DateTime> _lastPingTimes = {};

  // ─── Notification callback (set by providers.dart) ───
  void Function(String jobName, int fileCount, String deviceName)?
      onSyncBatchCompleted;

  // ═══════════════════════════════════════════════════════════════════════════
  // Persistence
  // ═══════════════════════════════════════════════════════════════════════════

  Future<void> _loadSavedJobs() async {
    try {
      final prefs = ref.read(sharedPreferencesProvider);
      final raw = prefs.getString(_prefSyncJobs);
      if (raw == null) return;

      final list = (jsonDecode(raw) as List<dynamic>)
          .map((e) => SyncJob.fromJson(e as Map<String, dynamic>))
          .toList();

      state = state.copyWith(jobs: list);

      // Start schedule timers for enabled schedules.
      for (final job in list) {
        if (job.schedule != null && job.schedule!.enabled) {
          _startScheduleTimer(job);
        }
      }
    } catch (e) {
      _log.warning('Failed to load saved sync jobs: $e');
    }
  }

  Future<void> _saveJobs() async {
    try {
      final prefs = ref.read(sharedPreferencesProvider);
      final json = state.jobs.map((j) => j.toJson()).toList();
      await prefs.setString(_prefSyncJobs, jsonEncode(json));
    } catch (e) {
      _log.warning('Failed to save sync jobs: $e');
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Job CRUD
  // ═══════════════════════════════════════════════════════════════════════════

  /// Creates a new sync job and persists it. Returns the job ID.
  Future<String> createJob({
    required String name,
    required String sourceDirectory,
    required Device target,
    SyncSchedule? schedule,
  }) async {
    final job = SyncJob(
      id: _uuid.v4(),
      name: name,
      sourceDirectory: sourceDirectory,
      targetDeviceId: target.id,
      targetDeviceName: target.name,
      targetDeviceIp: target.ip,
      createdAt: DateTime.now(),
      schedule: schedule,
    );

    state = state.addJob(job);
    await _saveJobs();

    if (schedule != null && schedule.enabled) {
      _startScheduleTimer(job);
    }

    _log.info('Created sync job "${job.name}" (${job.id})');
    return job.id;
  }

  /// Deletes a sync job — stops it first if running.
  Future<void> deleteJob(String jobId) async {
    _stopJobInternal(jobId);
    state = state.removeJob(jobId);
    await _saveJobs();
    _log.info('Deleted sync job $jobId');
  }

  /// Updates editable properties of a job.
  Future<void> updateJob(
    String jobId, {
    String? name,
    SyncSchedule? schedule,
    bool clearSchedule = false,
  }) async {
    final job = _findJob(jobId);
    if (job == null) return;

    final updated = job.copyWith(
      name: name,
      schedule: schedule,
      clearSchedule: clearSchedule,
    );
    state = state.updateJob(updated);
    await _saveJobs();

    // Re-arm schedule timer.
    _scheduleTimers[jobId]?.cancel();
    _scheduleTimers.remove(jobId);
    if (updated.schedule != null && updated.schedule!.enabled) {
      _startScheduleTimer(updated);
    }
  }

  /// Navigates the UI to the detail screen of a job.
  void selectJob(String? jobId) {
    state = state.copyWith(
      activeJobId: jobId,
      clearActiveJobId: jobId == null,
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Sync control — per job
  // ═══════════════════════════════════════════════════════════════════════════

  /// Starts (or restarts) a sync job.
  Future<void> startJob(String jobId) async {
    var job = _findJob(jobId);
    if (job == null) return;
    if (job.phase == SyncJobPhase.syncing) return; // Already running.

    final dir = Directory(job.sourceDirectory);
    if (!dir.existsSync()) {
      _updateJob(job.copyWith(phase: SyncJobPhase.error, status: 'sourceNotFound'));
      return;
    }

    // Reset runtime state.
    job = job.copyWith(
      phase: SyncJobPhase.syncing,
      status: 'syncInitialScan',
      fileItems: [],
      failedFiles: [],
      failedCount: 0,
      syncedCount: 0,
      totalBytes: 0,
      transferredBytes: 0,
      syncStartTime: DateTime.now(),
    );
    _updateJob(job);

    // Resolve target device IP from discovery.
    final targetDevice = _resolveDevice(job);
    if (targetDevice == null) {
      _updateJob(job.copyWith(phase: SyncJobPhase.error, status: 'syncCannotReach'));
      return;
    }

    // Ping check.
    final sender = ref.read(syncSenderProvider);
    final reachable = await sender.pingTarget(targetDevice);
    if (!reachable) {
      _updateJob(job.copyWith(phase: SyncJobPhase.error, status: 'syncCannotReach'));
      return;
    }
    _lastPingTimes[jobId] = DateTime.now();

    // Initial scan.
    try {
      final entities = dir.listSync(recursive: true);
      final pending = <String>{};
      for (final entity in entities) {
        if (entity is File) pending.add(entity.path);
      }
      _pendingFiles[jobId] = pending;
      _log.info('Job "$jobId": found ${pending.length} files.');

      _debounceTimers[jobId]?.cancel();
      _debounceTimers[jobId] =
          Timer(const Duration(milliseconds: 500), () => _processJobFiles(jobId));
    } catch (e) {
      _log.error('Initial scan failed for job $jobId: $e', error: e);
      _updateJob(job.copyWith(phase: SyncJobPhase.error, status: 'Initial scan failed'));
      return;
    }

    // Start watcher.
    _startWatcher(jobId, job.sourceDirectory);
  }

  /// Stops a running job — goes back to idle.
  void stopJob(String jobId) {
    _stopJobInternal(jobId);
    final job = _findJob(jobId);
    if (job == null) return;
    _updateJob(job.copyWith(
      phase: SyncJobPhase.idle,
      status: 'syncStopped',
    ));
    _log.info('Stopped job $jobId');
  }

  /// Pauses a syncing job — watcher keeps running but file sending pauses.
  void pauseJob(String jobId) {
    final job = _findJob(jobId);
    if (job == null || job.phase != SyncJobPhase.syncing) return;
    _updateJob(job.copyWith(phase: SyncJobPhase.paused, status: 'syncPaused'));
    _log.info('Paused job $jobId');
  }

  /// Resumes a paused job.
  void resumeJob(String jobId) {
    final job = _findJob(jobId);
    if (job == null || job.phase != SyncJobPhase.paused) return;
    _updateJob(job.copyWith(phase: SyncJobPhase.syncing, status: 'syncing'));
    _log.info('Resumed job $jobId');

    // Re-process pending items.
    final pendingItems = job.fileItems
        .where((f) => f.status == SyncFileStatus.pending)
        .toList();
    if (pendingItems.isNotEmpty) {
      final pending = _pendingFiles.putIfAbsent(jobId, () => <String>{});
      for (final item in pendingItems) {
        pending.add(p.join(job.sourceDirectory, item.relativePath));
      }
      _debounceTimers[jobId]?.cancel();
      _debounceTimers[jobId] =
          Timer(const Duration(milliseconds: 200), () => _processJobFiles(jobId));
    }
  }

  /// Skip a specific file in a job by index.
  void skipFile(String jobId, int index) {
    final job = _findJob(jobId);
    if (job == null || index < 0 || index >= job.fileItems.length) return;
    if (job.fileItems[index].status != SyncFileStatus.pending) return;
    final items = List<SyncFileItem>.from(job.fileItems);
    items[index] = items[index].copyWith(status: SyncFileStatus.skipped);
    _updateJob(job.copyWith(fileItems: items));
  }

  /// Stops all running jobs.
  void stopAll() {
    for (final job in state.jobs) {
      if (job.isActive) stopJob(job.id);
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Receiver side
  // ═══════════════════════════════════════════════════════════════════════════

  void onFileReceived(String relativePath, String senderName, String savedPath) {
    final newItem = SyncFileItem(
      relativePath: relativePath,
      status: SyncFileStatus.completed,
      completedAt: DateTime.now(),
    );

    state = state.copyWith(
      isReceiving: true,
      receiverSenderName: senderName,
      receivedItems: [...state.receivedItems, newItem],
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Internal: watcher per job
  // ═══════════════════════════════════════════════════════════════════════════

  void _startWatcher(String jobId, String directory) {
    _watchers[jobId]?.cancel();
    try {
      final watcher = DirectoryWatcher(directory);
      _watchers[jobId] = watcher.events.listen(
        (event) => _handleFileEvent(jobId, event),
        onError: (e) {
          _log.error('Watcher error for job $jobId: $e', error: e);
        },
      );
      _log.info('Started watcher for job $jobId');
    } catch (e) {
      _log.error('Failed to start watcher for job $jobId: $e', error: e);
    }
  }

  void _handleFileEvent(String jobId, WatchEvent event) {
    if (event.type == ChangeType.REMOVE) {
      _handleDeleteEvent(jobId, event.path);
      return;
    }

    try {
      if (FileSystemEntity.isDirectorySync(event.path)) return;
    } catch (_) {
      return;
    }

    _log.debug('Job $jobId: file changed ${event.path}');

    final pending = _pendingFiles.putIfAbsent(jobId, () => <String>{});
    pending.add(event.path);
    _debounceTimers[jobId]?.cancel();
    _debounceTimers[jobId] =
        Timer(const Duration(seconds: 2), () => _processJobFiles(jobId));

    // Transition watching → syncing.
    final job = _findJob(jobId);
    if (job != null && job.phase == SyncJobPhase.watching) {
      _updateJob(job.copyWith(phase: SyncJobPhase.syncing, status: 'syncChangeDetected'));
    }
  }

  Future<void> _handleDeleteEvent(String jobId, String path) async {
    final job = _findJob(jobId);
    if (job == null) return;

    final targetDevice = _resolveDevice(job);
    if (targetDevice == null) return;

    _log.info('Job $jobId: file deleted $path');
    final sender = ref.read(syncSenderProvider);
    await sender.sendDelete(targetDevice, path, job.sourceDirectory);
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Internal: process pending files for a job
  // ═══════════════════════════════════════════════════════════════════════════

  Future<void> _processJobFiles(String jobId) async {
    final pending = _pendingFiles[jobId];
    if (pending == null || pending.isEmpty) return;

    var job = _findJob(jobId);
    if (job == null) return;

    final targetDevice = _resolveDevice(job);
    if (targetDevice == null) {
      _updateJob(job.copyWith(phase: SyncJobPhase.error, status: 'syncCannotReach'));
      return;
    }

    final filesToSync = List<String>.from(pending);
    pending.clear();

    final sender = ref.read(syncSenderProvider);

    // Build file items.
    final items = <SyncFileItem>[];
    int totalBytes = 0;
    for (final filePath in filesToSync) {
      final file = File(filePath);
      final relPath = p.relative(filePath, from: job.sourceDirectory)
          .replaceAll(r'\', '/');
      final size = file.existsSync() ? file.lengthSync() : 0;
      totalBytes += size;
      items.add(SyncFileItem(
        relativePath: relPath,
        status: SyncFileStatus.pending,
        fileSize: size,
      ));
    }

    job = job.copyWith(
      phase: SyncJobPhase.syncing,
      status: 'syncing',
      fileItems: items,
      failedFiles: [],
      failedCount: 0,
      syncedCount: 0,
      totalBytes: totalBytes,
      transferredBytes: 0,
      syncStartTime: DateTime.now(),
    );
    _updateJob(job);

    int successCount = 0;
    int transferredBytes = 0;
    final failures = <SyncError>[];

    for (int i = 0; i < filesToSync.length; i++) {
      // Re-read job (state may have been modified by pause/stop/skip).
      job = _findJob(jobId);
      if (job == null || job.phase == SyncJobPhase.idle) break;

      // Pause loop.
      while (job != null && job.phase == SyncJobPhase.paused) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        job = _findJob(jobId);
      }
      if (job == null || job.phase == SyncJobPhase.idle) break;

      // Skipped?
      if (job.fileItems.length > i &&
          job.fileItems[i].status == SyncFileStatus.skipped) {
        continue;
      }

      final filePath = filesToSync[i];
      final file = File(filePath);
      final fileSize = file.existsSync() ? file.lengthSync() : 0;
      final relPath = items[i].relativePath;

      // Mark as syncing.
      final updatedItems = List<SyncFileItem>.from(job.fileItems);
      updatedItems[i] = updatedItems[i].copyWith(status: SyncFileStatus.syncing);
      _updateJob(job.copyWith(fileItems: updatedItems));

      // ── Periodic ping check ──
      if (i > 0 && i % 10 == 0) {
        final lastPing = _lastPingTimes[jobId];
        if (lastPing == null ||
            DateTime.now().difference(lastPing).inMinutes >= 5) {
          final reachable = await sender.pingTarget(targetDevice);
          if (reachable) {
            _lastPingTimes[jobId] = DateTime.now();
          } else {
            final reconnected = await _waitForReconnection(jobId, sender, targetDevice);
            if (!reconnected) {
              _updateJob(job.copyWith(phase: SyncJobPhase.error, status: 'syncCannotReach'));
              return;
            }
          }
        }
      }

      // ── Smart sync: check remote file ──
      if (file.existsSync()) {
        final discoveryService =
            ref.read(discoveryServiceProvider).valueOrNull;
        final senderName = discoveryService?.localDevice.name ?? 'Unknown';

        final remoteStatus = await sender.checkFileStatus(
          targetDevice, relPath, senderName,
        );

        if (remoteStatus != null && remoteStatus['exists'] == true) {
          final remoteSize = remoteStatus['size'] as int? ?? -1;
          final remoteModifiedStr = remoteStatus['lastModified'] as String?;
          if (remoteSize == fileSize && remoteModifiedStr != null) {
            try {
              final remoteModified = DateTime.parse(remoteModifiedStr);
              final localModified = file.lastModifiedSync();
              if (!localModified.isAfter(remoteModified)) {
                final skipItems = List<SyncFileItem>.from(job.fileItems);
                skipItems[i] = skipItems[i].copyWith(status: SyncFileStatus.skipped);
                transferredBytes += fileSize;
                _updateJob(job.copyWith(
                  fileItems: skipItems,
                  transferredBytes: transferredBytes,
                ));
                continue;
              }
            } catch (_) {}
          }
        }
      }

      // ── Send file with retries ──
      String? lastError;
      bool success = false;

      for (int attempt = 1; attempt <= _maxRetries + 1; attempt++) {
        lastError = await sender.sendFile(targetDevice, filePath, job.sourceDirectory);
        success = lastError == null;
        if (success) break;
        if (attempt <= _maxRetries) {
          await Future<void>.delayed(Duration(seconds: attempt));
        }
      }

      transferredBytes += fileSize;

      // Re-read job state.
      job = _findJob(jobId);
      if (job == null) break;

      if (success) {
        successCount++;
        final doneItems = List<SyncFileItem>.from(job.fileItems);
        doneItems[i] = doneItems[i].copyWith(
          status: SyncFileStatus.completed,
          completedAt: DateTime.now(),
        );
        _updateJob(job.copyWith(
          fileItems: doneItems,
          syncedCount: successCount,
          transferredBytes: transferredBytes,
        ));
      } else {
        failures.add(SyncError(
          filePath: relPath,
          error: lastError ?? 'Unknown error',
          timestamp: DateTime.now(),
        ));
        final failItems = List<SyncFileItem>.from(job.fileItems);
        failItems[i] = failItems[i].copyWith(
          status: SyncFileStatus.failed,
          error: lastError,
        );
        _updateJob(job.copyWith(
          fileItems: failItems,
          failedCount: failures.length,
          transferredBytes: transferredBytes,
        ));
      }
    }

    // ── Batch complete ──
    job = _findJob(jobId);
    if (job == null) return;

    _log.info(
      'Job "$jobId": synced $successCount/${filesToSync.length} files '
      '(${failures.length} failed)',
    );

    _updateJob(job.copyWith(
      phase: SyncJobPhase.watching,
      lastSyncTime: DateTime.now(),
      status: failures.isEmpty ? 'syncCompleted' : 'syncCompleted',
      syncedCount: successCount,
      failedCount: failures.length,
      failedFiles: failures,
    ));
    _saveJobs();

    // Fire summary notification.
    onSyncBatchCompleted?.call(
      job.name, successCount, job.targetDeviceName,
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Internal: reconnection
  // ═══════════════════════════════════════════════════════════════════════════

  Future<bool> _waitForReconnection(
    String jobId, SyncSender sender, Device target,
  ) async {
    final job = _findJob(jobId);
    if (job != null) {
      _updateJob(job.copyWith(status: 'syncReconnecting'));
    }

    const delays = [30, 60, 120]; // seconds
    for (final delay in delays) {
      await Future<void>.delayed(Duration(seconds: delay));
      if (await sender.pingTarget(target)) {
        _lastPingTimes[jobId] = DateTime.now();
        final j = _findJob(jobId);
        if (j != null) _updateJob(j.copyWith(status: 'syncing'));
        return true;
      }
    }
    return false;
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Internal: schedule
  // ═══════════════════════════════════════════════════════════════════════════

  void _startScheduleTimer(SyncJob job) {
    _scheduleTimers[job.id]?.cancel();
    final schedule = job.schedule;
    if (schedule == null || !schedule.enabled) return;

    if (schedule.type == ScheduleType.interval && schedule.interval != null) {
      _scheduleTimers[job.id] = Timer.periodic(schedule.interval!, (_) {
        _tryScheduledSync(job.id);
      });
    } else {
      _scheduleTimers[job.id] = Timer.periodic(const Duration(minutes: 1), (_) {
        _checkTimeBasedSchedule(job.id, schedule);
      });
    }
  }

  void _checkTimeBasedSchedule(String jobId, SyncSchedule schedule) {
    if (schedule.time == null) return;
    final now = DateTime.now();
    final currentTime = TimeOfDay.fromDateTime(now);

    if (currentTime.hour != schedule.time!.hour ||
        currentTime.minute != schedule.time!.minute) {
      return;
    }

    if (schedule.type == ScheduleType.weekly && schedule.weekDays.isNotEmpty) {
      if (!schedule.weekDays.contains(now.weekday)) return;
    }

    _tryScheduledSync(jobId);
  }

  void _tryScheduledSync(String jobId) {
    final job = _findJob(jobId);
    if (job == null) return;
    if (job.phase == SyncJobPhase.syncing) return; // Already running.

    final dir = Directory(job.sourceDirectory);
    if (!dir.existsSync()) {
      _log.warning('Scheduled sync skipped for "$jobId": source dir missing');
      return;
    }

    _log.info('Starting scheduled sync for job "${job.name}"');
    startJob(jobId);
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Helpers
  // ═══════════════════════════════════════════════════════════════════════════

  SyncJob? _findJob(String jobId) {
    final idx = state.jobs.indexWhere((j) => j.id == jobId);
    return idx >= 0 ? state.jobs[idx] : null;
  }

  void _updateJob(SyncJob job) {
    state = state.updateJob(job);
  }

  /// Resolves a [Device] instance for the job's target from the discovery service,
  /// falling back to cached IP from the job itself.
  Device? _resolveDevice(SyncJob job) {
    try {
      final deviceList = ref.read(devicesProvider).valueOrNull ?? [];
      final match = deviceList.cast<Device>().firstWhere(
        (d) => d.id == job.targetDeviceId,
        orElse: () => Device(
          id: job.targetDeviceId,
          name: job.targetDeviceName,
          ip: job.targetDeviceIp ?? '',
          port: 0,
          platform: 'unknown',
          version: '',
          lastSeen: DateTime.now(),
        ),
      );
      if (match.ip.isEmpty) return null;
      return match;
    } catch (_) {
      if (job.targetDeviceIp != null && job.targetDeviceIp!.isNotEmpty) {
        return Device(
          id: job.targetDeviceId,
          name: job.targetDeviceName,
          ip: job.targetDeviceIp!,
          port: 0,
          platform: 'unknown',
          version: '',
          lastSeen: DateTime.now(),
        );
      }
      return null;
    }
  }

  void _stopJobInternal(String jobId) {
    _watchers[jobId]?.cancel();
    _watchers.remove(jobId);
    _debounceTimers[jobId]?.cancel();
    _debounceTimers.remove(jobId);
    _scheduleTimers[jobId]?.cancel();
    _scheduleTimers.remove(jobId);
    _pendingFiles.remove(jobId);
    _lastPingTimes.remove(jobId);
  }

  @override
  void dispose() {
    for (final sub in _watchers.values) {
      sub.cancel();
    }
    for (final timer in _debounceTimers.values) {
      timer?.cancel();
    }
    for (final timer in _scheduleTimers.values) {
      timer?.cancel();
    }
    super.dispose();
  }
}
