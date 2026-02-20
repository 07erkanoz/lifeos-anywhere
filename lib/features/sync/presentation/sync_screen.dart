import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:anyware/core/theme.dart';
import 'package:anyware/features/discovery/domain/device.dart';
import 'package:anyware/features/discovery/presentation/providers.dart';
import 'package:anyware/features/sync/data/sync_service.dart';
import 'package:anyware/features/sync/domain/sync_state.dart';
import 'package:anyware/features/settings/presentation/providers.dart';
import 'package:anyware/widgets/glassmorphism.dart';
import 'package:anyware/i18n/app_localizations.dart';

class SyncScreen extends ConsumerStatefulWidget {
  const SyncScreen({super.key});

  @override
  ConsumerState<SyncScreen> createState() => _SyncScreenState();
}

class _SyncScreenState extends ConsumerState<SyncScreen> {
  final ScrollController _fileListController = ScrollController();

  @override
  void dispose() {
    _fileListController.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_fileListController.hasClients) {
        _fileListController.animateTo(
          _fileListController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final syncState = ref.watch(syncServiceProvider);
    final settings = ref.watch(settingsProvider);
    final locale = settings.locale;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // If a job is selected, show its detail screen.
    if (syncState.activeJobId != null && syncState.selectedJob != null) {
      return _buildJobDetailView(context, syncState, locale, isDark);
    }

    // Otherwise show the job list.
    return _buildJobListView(context, syncState, locale, isDark);
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Job List View
  // ═══════════════════════════════════════════════════════════════════════════

  Widget _buildJobListView(
    BuildContext context, SyncState syncState, String locale, bool isDark,
  ) {
    final syncService = ref.read(syncServiceProvider.notifier);
    final jobs = syncState.jobs;

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: Text(AppLocalizations.get('folderSync', locale)),
        backgroundColor: Colors.transparent,
        automaticallyImplyLeading: false,
        actions: [
          IconButton(
            icon: const Icon(Icons.add_rounded),
            tooltip: AppLocalizations.get('newSync', locale),
            onPressed: () => _showCreateJobDialog(context, locale, isDark),
          ),
        ],
      ),
      body: jobs.isEmpty
          ? _buildEmptyState(locale, isDark)
          : ListView(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              children: [
                // Job cards.
                for (final job in jobs) ...[
                  _buildJobCard(context, job, locale, isDark, syncService),
                  const SizedBox(height: 12),
                ],

                // Receiver section.
                if (syncState.isReceiving) ...[
                  const Divider(),
                  _buildReceiverSection(syncState, locale, isDark),
                ],
              ],
            ),
    );
  }

  Widget _buildEmptyState(String locale, bool isDark) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.sync_rounded, size: 64, color: Colors.grey.shade600),
          const SizedBox(height: 16),
          Text(
            AppLocalizations.get('noSyncJobs', locale),
            style: TextStyle(color: Colors.grey.shade500, fontSize: 16),
          ),
          const SizedBox(height: 24),
          ElevatedButton.icon(
            onPressed: () => _showCreateJobDialog(
              context, locale, Theme.of(context).brightness == Brightness.dark,
            ),
            icon: const Icon(Icons.add_rounded),
            label: Text(AppLocalizations.get('createSync', locale)),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.neonBlue,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            ),
          ),
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Job Card
  // ═══════════════════════════════════════════════════════════════════════════

  Widget _buildJobCard(
    BuildContext context, SyncJob job, String locale, bool isDark,
    SyncService syncService,
  ) {
    final statusInfo = _jobStatusInfo(job, locale);

    return GlassmorphismCard(
      borderRadius: 16,
      padding: const EdgeInsets.all(16),
      onTap: () => syncService.selectJob(job.id),
      child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header: name + phase icon.
              Row(
                children: [
                  Expanded(
                    child: Text(
                      job.name,
                      style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 16,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  _phaseIcon(job.phase),
                ],
              ),
              const SizedBox(height: 8),

              // Source → Target.
              Row(
                children: [
                  const Icon(Icons.folder_rounded, size: 14, color: Colors.grey),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      '${_shortenPath(job.sourceDirectory)}  →  ${job.targetDeviceName}',
                      style: const TextStyle(color: Colors.grey, fontSize: 12),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),

              // Status text.
              Row(
                children: [
                  Icon(statusInfo.icon, size: 14, color: statusInfo.color),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      statusInfo.label,
                      style: TextStyle(color: statusInfo.color, fontSize: 12),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),

              // Progress bar (only when syncing).
              if (job.phase == SyncJobPhase.syncing && job.totalBytes > 0) ...[
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: job.progress,
                    backgroundColor: Colors.grey.shade800,
                    valueColor: const AlwaysStoppedAnimation(AppColors.neonBlue),
                    minHeight: 4,
                  ),
                ),
                const SizedBox(height: 4),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      '${job.syncedCount} / ${job.fileItems.length}',
                      style: const TextStyle(color: Colors.grey, fontSize: 11),
                    ),
                    Text(
                      _formatSpeed(job),
                      style: const TextStyle(color: AppColors.neonBlue, fontSize: 11),
                    ),
                  ],
                ),
              ],

              // Schedule badge.
              if (job.schedule != null && job.schedule!.enabled) ...[
                const SizedBox(height: 6),
                Row(
                  children: [
                    const Icon(Icons.schedule_rounded, size: 12, color: Colors.grey),
                    const SizedBox(width: 4),
                    Text(
                      _formatScheduleLabel(job.schedule!, locale),
                      style: const TextStyle(color: Colors.grey, fontSize: 11),
                    ),
                  ],
                ),
              ],
            ],
          ),
    );
  }

  Widget _phaseIcon(SyncJobPhase phase) {
    switch (phase) {
      case SyncJobPhase.idle:
        return const Icon(Icons.circle_outlined, size: 18, color: Colors.grey);
      case SyncJobPhase.syncing:
        return const SizedBox(
          width: 18, height: 18,
          child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.neonBlue),
        );
      case SyncJobPhase.watching:
        return const Icon(Icons.check_circle_rounded, size: 18, color: AppColors.neonGreen);
      case SyncJobPhase.error:
        return const Icon(Icons.warning_amber_rounded, size: 18, color: Colors.orange);
      case SyncJobPhase.paused:
        return const Icon(Icons.pause_circle_rounded, size: 18, color: Colors.amber);
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Job Detail View
  // ═══════════════════════════════════════════════════════════════════════════

  Widget _buildJobDetailView(
    BuildContext context, SyncState syncState, String locale, bool isDark,
  ) {
    final syncService = ref.read(syncServiceProvider.notifier);
    final job = syncState.selectedJob!;

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () => syncService.selectJob(null),
        ),
        title: Text(job.name, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            icon: const Icon(Icons.schedule_rounded),
            tooltip: AppLocalizations.get('scheduleSync', locale),
            onPressed: () => _showScheduleDialog(context, locale, job, syncService),
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline_rounded),
            tooltip: AppLocalizations.get('deleteSync', locale),
            onPressed: () => _confirmDeleteJob(context, locale, job, syncService),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Column(
          children: [
            // Info card.
            _buildJobInfoCard(job, locale, isDark),
            const SizedBox(height: 12),

            // Status section.
            _buildJobStatusSection(job, locale),
            const SizedBox(height: 12),

            // File list.
            Expanded(child: _buildFileList(job, locale, isDark, syncService)),

            // Action bar.
            _buildJobActions(job, locale, syncService),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  Widget _buildJobInfoCard(SyncJob job, String locale, bool isDark) {
    return GlassmorphismCard(
      borderRadius: 12,
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.folder_rounded, size: 16, color: AppColors.neonBlue),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  job.sourceDirectory,
                  style: const TextStyle(fontSize: 12),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              const Icon(Icons.devices_rounded, size: 16, color: AppColors.neonGreen),
              const SizedBox(width: 6),
              Text(
                '${job.targetDeviceName}${job.targetDeviceIp != null ? " (${job.targetDeviceIp})" : ""}',
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ],
          ),
          if (job.schedule != null && job.schedule!.enabled) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                const Icon(Icons.schedule_rounded, size: 16, color: Colors.amber),
                const SizedBox(width: 6),
                Text(
                  _formatScheduleLabel(job.schedule!, locale),
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildJobStatusSection(SyncJob job, String locale) {
    final statusInfo = _jobStatusInfo(job, locale);
    return Row(
      children: [
        Icon(statusInfo.icon, size: 20, color: statusInfo.color),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                statusInfo.label,
                style: TextStyle(
                  color: statusInfo.color,
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                ),
              ),
              if (job.lastSyncTime != null)
                Text(
                  '${AppLocalizations.get('syncLastChange', locale).replaceAll('{time}', _formatTime(job.lastSyncTime!))} · ${job.syncedCount}/${job.fileItems.length}',
                  style: const TextStyle(color: Colors.grey, fontSize: 11),
                ),
            ],
          ),
        ),
        if (job.phase == SyncJobPhase.syncing && job.totalBytes > 0)
          Text(
            job.progressPercent,
            style: const TextStyle(
              color: AppColors.neonBlue,
              fontWeight: FontWeight.bold,
              fontSize: 18,
            ),
          ),
      ],
    );
  }

  Widget _buildFileList(
    SyncJob job, String locale, bool isDark, SyncService syncService,
  ) {
    final items = job.fileItems;
    if (items.isEmpty) {
      return Center(
        child: Text(
          job.phase == SyncJobPhase.watching
              ? AppLocalizations.get('syncWatchingDesc', locale)
              : '',
          style: const TextStyle(color: Colors.grey),
        ),
      );
    }

    if (job.phase == SyncJobPhase.syncing) _scrollToBottom();

    return ListView.builder(
      controller: _fileListController,
      itemCount: items.length,
      itemBuilder: (context, index) {
        final item = items[index];
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(
            children: [
              _fileStatusIcon(item.status),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.relativePath,
                      style: TextStyle(
                        fontSize: 12,
                        color: item.status == SyncFileStatus.failed
                            ? Colors.red.shade300
                            : null,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (item.error != null)
                      Text(
                        item.error!,
                        style: TextStyle(
                          fontSize: 10, color: Colors.red.shade400,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
                ),
              ),
              Text(
                _formatBytes(item.fileSize),
                style: const TextStyle(color: Colors.grey, fontSize: 11),
              ),
              if (item.status == SyncFileStatus.pending)
                IconButton(
                  icon: const Icon(Icons.skip_next_rounded, size: 18),
                  constraints: const BoxConstraints(minWidth: 32),
                  padding: EdgeInsets.zero,
                  onPressed: () => syncService.skipFile(job.id, index),
                  tooltip: AppLocalizations.get('skipFile', locale),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildJobActions(SyncJob job, String locale, SyncService syncService) {
    return Row(
      children: [
        // Start / Resume.
        if (job.phase == SyncJobPhase.idle ||
            job.phase == SyncJobPhase.error)
          Expanded(
            child: ElevatedButton.icon(
              onPressed: () => syncService.startJob(job.id),
              icon: const Icon(Icons.play_arrow_rounded, size: 18),
              label: Text(AppLocalizations.get('syncNow', locale)),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.neonBlue,
                foregroundColor: Colors.white,
              ),
            ),
          ),

        if (job.phase == SyncJobPhase.paused) ...[
          Expanded(
            child: ElevatedButton.icon(
              onPressed: () => syncService.resumeJob(job.id),
              icon: const Icon(Icons.play_arrow_rounded, size: 18),
              label: Text(AppLocalizations.get('resumeSync', locale)),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.neonBlue,
                foregroundColor: Colors.white,
              ),
            ),
          ),
          const SizedBox(width: 8),
        ],

        // Pause.
        if (job.phase == SyncJobPhase.syncing)
          Expanded(
            child: OutlinedButton.icon(
              onPressed: () => syncService.pauseJob(job.id),
              icon: const Icon(Icons.pause_rounded, size: 18),
              label: Text(AppLocalizations.get('pauseSync', locale)),
            ),
          ),

        // Stop.
        if (job.phase == SyncJobPhase.syncing ||
            job.phase == SyncJobPhase.watching ||
            job.phase == SyncJobPhase.paused) ...[
          const SizedBox(width: 8),
          Expanded(
            child: ElevatedButton.icon(
              onPressed: () => syncService.stopJob(job.id),
              icon: const Icon(Icons.stop_rounded, size: 18),
              label: Text(AppLocalizations.get('stopSync', locale)),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red.shade700,
                foregroundColor: Colors.white,
              ),
            ),
          ),
        ],
      ],
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Receiver Section
  // ═══════════════════════════════════════════════════════════════════════════

  Widget _buildReceiverSection(SyncState syncState, String locale, bool isDark) {
    return GlassmorphismCard(
      borderRadius: 12,
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.download_rounded, size: 18, color: AppColors.neonGreen),
              const SizedBox(width: 6),
              Text(
                AppLocalizations.get('syncReceiving', locale)
                    .replaceAll('{device}', syncState.receiverSenderName ?? ''),
                style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
              ),
            ],
          ),
          const SizedBox(height: 8),
          for (final item in syncState.receivedItems.reversed.take(20))
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  _fileStatusIcon(item.status),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      item.relativePath,
                      style: const TextStyle(fontSize: 12),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Create Job Dialog
  // ═══════════════════════════════════════════════════════════════════════════

  void _showCreateJobDialog(BuildContext context, String locale, bool isDark) {
    final devices = ref.read(devicesProvider).valueOrNull ?? [];
    final syncDevices = devices.toList();

    String name = '';
    String? sourceDir;
    Device? selectedDevice;

    showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            return AlertDialog(
              title: Text(AppLocalizations.get('newSync', locale)),
              content: SizedBox(
                width: 360,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Name.
                    TextField(
                      decoration: InputDecoration(
                        labelText: AppLocalizations.get('syncName', locale),
                        hintText: 'Documents → Laptop',
                      ),
                      onChanged: (v) => name = v,
                    ),
                    const SizedBox(height: 16),

                    // Source folder.
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            sourceDir ?? AppLocalizations.get('syncSource', locale),
                            style: TextStyle(
                              fontSize: 13,
                              color: sourceDir != null ? null : Colors.grey,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        TextButton.icon(
                          onPressed: () async {
                            final result = await FilePicker.platform.getDirectoryPath();
                            if (result != null) {
                              setDialogState(() => sourceDir = result);
                              if (name.isEmpty) {
                                name = result.split(RegExp(r'[/\\]')).last;
                              }
                            }
                          },
                          icon: const Icon(Icons.folder_open_rounded, size: 18),
                          label: Text(AppLocalizations.get('browse', locale)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),

                    // Target device.
                    if (syncDevices.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Text(
                          AppLocalizations.get('noSyncDevices', locale),
                          style: const TextStyle(color: Colors.grey),
                        ),
                      )
                    else
                      DropdownButtonFormField<Device>(
                        initialValue: selectedDevice,
                        decoration: InputDecoration(
                          labelText: AppLocalizations.get('syncTarget', locale),
                        ),
                        items: syncDevices.map((d) {
                          return DropdownMenuItem(
                            value: d,
                            child: Text('${d.name} (${d.ip})'),
                          );
                        }).toList(),
                        onChanged: (d) => setDialogState(() => selectedDevice = d),
                      ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: Text(AppLocalizations.get('cancel', locale)),
                ),
                FilledButton(
                  onPressed: (sourceDir != null && selectedDevice != null && name.isNotEmpty)
                      ? () async {
                          Navigator.of(ctx).pop();
                          final syncService = ref.read(syncServiceProvider.notifier);
                          final jobId = await syncService.createJob(
                            name: name,
                            sourceDirectory: sourceDir!,
                            target: selectedDevice!,
                          );
                          // Auto-start the new job.
                          await syncService.startJob(jobId);
                          syncService.selectJob(jobId);
                        }
                      : null,
                  child: Text(AppLocalizations.get('createSync', locale)),
                ),
              ],
            );
          },
        );
      },
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Schedule Dialog
  // ═══════════════════════════════════════════════════════════════════════════

  void _showScheduleDialog(
    BuildContext context, String locale, SyncJob job, SyncService syncService,
  ) {
    var scheduleType = job.schedule?.type ?? ScheduleType.interval;
    var selectedTime = job.schedule?.time ?? const TimeOfDay(hour: 9, minute: 0);
    var selectedDays = List<int>.from(job.schedule?.weekDays ?? [1, 2, 3, 4, 5]);
    var selectedInterval = job.schedule?.interval ?? const Duration(minutes: 30);
    var enabled = job.schedule?.enabled ?? true;

    final intervals = [
      const Duration(minutes: 30),
      const Duration(hours: 1),
      const Duration(hours: 2),
      const Duration(hours: 6),
      const Duration(hours: 12),
      const Duration(hours: 24),
    ];

    showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            return AlertDialog(
              title: Text(AppLocalizations.get('scheduleSyncTitle', locale)),
              content: SizedBox(
                width: 360,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SwitchListTile(
                      title: Text(AppLocalizations.get('scheduleSync', locale)),
                      value: enabled,
                      onChanged: (v) => setDialogState(() => enabled = v),
                      contentPadding: EdgeInsets.zero,
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      children: [
                        ChoiceChip(
                          label: Text(AppLocalizations.get('scheduleAtTime', locale)),
                          selected: scheduleType != ScheduleType.interval,
                          onSelected: (_) => setDialogState(
                            () => scheduleType = ScheduleType.daily,
                          ),
                        ),
                        ChoiceChip(
                          label: Text(AppLocalizations.get('scheduleInterval', locale)),
                          selected: scheduleType == ScheduleType.interval,
                          onSelected: (_) => setDialogState(
                            () => scheduleType = ScheduleType.interval,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),

                    if (scheduleType != ScheduleType.interval) ...[
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(selectedTime.format(ctx)),
                        trailing: const Icon(Icons.access_time_rounded),
                        onTap: () async {
                          final picked = await showTimePicker(
                            context: ctx,
                            initialTime: selectedTime,
                          );
                          if (picked != null) {
                            setDialogState(() => selectedTime = picked);
                          }
                        },
                      ),
                      Wrap(
                        spacing: 6,
                        children: [
                          for (int day = 1; day <= 7; day++)
                            FilterChip(
                              label: Text(_dayLabel(day, locale)),
                              selected: selectedDays.contains(day),
                              onSelected: (v) {
                                setDialogState(() {
                                  if (v) {
                                    selectedDays.add(day);
                                  } else {
                                    selectedDays.remove(day);
                                  }
                                  scheduleType = selectedDays.length == 7
                                      ? ScheduleType.daily
                                      : ScheduleType.weekly;
                                });
                              },
                            ),
                        ],
                      ),
                    ] else ...[
                      Wrap(
                        spacing: 8,
                        children: intervals.map((d) {
                          return ChoiceChip(
                            label: Text(_formatDuration(d, locale)),
                            selected: selectedInterval.inMinutes == d.inMinutes,
                            onSelected: (_) =>
                                setDialogState(() => selectedInterval = d),
                          );
                        }).toList(),
                      ),
                    ],
                  ],
                ),
              ),
              actions: [
                if (job.schedule != null)
                  TextButton(
                    onPressed: () {
                      syncService.updateJob(job.id, clearSchedule: true);
                      Navigator.of(ctx).pop();
                    },
                    child: Text(
                      AppLocalizations.get('deleteSync', locale),
                      style: const TextStyle(color: Colors.red),
                    ),
                  ),
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: Text(AppLocalizations.get('cancel', locale)),
                ),
                FilledButton(
                  onPressed: () {
                    final schedule = SyncSchedule(
                      type: scheduleType,
                      time: scheduleType != ScheduleType.interval ? selectedTime : null,
                      weekDays: scheduleType == ScheduleType.weekly ? selectedDays : [],
                      interval: scheduleType == ScheduleType.interval ? selectedInterval : null,
                      enabled: enabled,
                    );
                    syncService.updateJob(job.id, schedule: schedule);
                    Navigator.of(ctx).pop();
                  },
                  child: Text(AppLocalizations.get('save', locale)),
                ),
              ],
            );
          },
        );
      },
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Delete Confirmation
  // ═══════════════════════════════════════════════════════════════════════════

  void _confirmDeleteJob(
    BuildContext context, String locale, SyncJob job, SyncService syncService,
  ) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(AppLocalizations.get('deleteSync', locale)),
        content: Text(AppLocalizations.get('deleteConfirm', locale)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(AppLocalizations.get('cancel', locale)),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              syncService.selectJob(null);
              syncService.deleteJob(job.id);
            },
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: Text(AppLocalizations.get('deleteSync', locale)),
          ),
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Helpers
  // ═══════════════════════════════════════════════════════════════════════════

  Widget _fileStatusIcon(SyncFileStatus status) {
    switch (status) {
      case SyncFileStatus.completed:
        return const Icon(Icons.check_circle_rounded, size: 16, color: AppColors.neonGreen);
      case SyncFileStatus.failed:
        return const Icon(Icons.error_rounded, size: 16, color: Colors.red);
      case SyncFileStatus.skipped:
        return const Icon(Icons.skip_next_rounded, size: 16, color: Colors.grey);
      case SyncFileStatus.syncing:
        return const SizedBox(
          width: 16, height: 16,
          child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.neonBlue),
        );
      case SyncFileStatus.paused:
        return const Icon(Icons.pause_circle_rounded, size: 16, color: Colors.amber);
      case SyncFileStatus.pending:
        return const Icon(Icons.circle_outlined, size: 16, color: Colors.grey);
    }
  }

  _JobStatusInfo _jobStatusInfo(SyncJob job, String locale) {
    switch (job.phase) {
      case SyncJobPhase.idle:
        if (job.lastSyncTime != null) {
          return _JobStatusInfo(
            Icons.check_circle_outlined, Colors.grey,
            '${AppLocalizations.get('syncCompleted', locale)} · ${_formatTime(job.lastSyncTime!)}',
          );
        }
        return _JobStatusInfo(Icons.circle_outlined, Colors.grey, AppLocalizations.get('stopSync', locale));
      case SyncJobPhase.syncing:
        if (job.status == 'syncInitialScan') {
          return _JobStatusInfo(Icons.search_rounded, AppColors.neonBlue,
              AppLocalizations.get('syncInitialScan', locale));
        }
        if (job.status == 'syncReconnecting') {
          return _JobStatusInfo(Icons.wifi_find_rounded, Colors.orange,
              AppLocalizations.get('syncReconnecting', locale));
        }
        return _JobStatusInfo(
          Icons.sync_rounded, AppColors.neonBlue,
          AppLocalizations.get('syncProgress', locale).replaceAll('{synced}', '${job.syncedCount}').replaceAll('{total}', '${job.fileItems.length}'),
        );
      case SyncJobPhase.watching:
        return _JobStatusInfo(Icons.visibility_rounded, AppColors.neonGreen,
            AppLocalizations.get('syncWatching', locale));
      case SyncJobPhase.error:
        if (job.status == 'syncCannotReach') {
          return _JobStatusInfo(Icons.wifi_off_rounded, Colors.red,
              AppLocalizations.get('syncConnectionLost', locale));
        }
        return _JobStatusInfo(Icons.error_outline_rounded, Colors.red, job.status ?? 'Error');
      case SyncJobPhase.paused:
        return _JobStatusInfo(Icons.pause_rounded, Colors.amber,
            AppLocalizations.get('syncPaused', locale));
    }
  }

  String _shortenPath(String path) {
    final parts = path.split(RegExp(r'[/\\]'));
    if (parts.length <= 3) return path;
    return '.../${parts.sublist(parts.length - 2).join('/')}';
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  String _formatSpeed(SyncJob job) {
    if (job.syncStartTime == null) return '';
    final elapsed = DateTime.now().difference(job.syncStartTime!).inSeconds;
    if (elapsed <= 0) return '';
    final bytesPerSec = job.transferredBytes / elapsed;
    return '${_formatBytes(bytesPerSec.toInt())}/s';
  }

  String _formatTime(DateTime dt) {
    return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  String _formatScheduleLabel(SyncSchedule schedule, String locale) {
    if (schedule.type == ScheduleType.interval && schedule.interval != null) {
      return AppLocalizations.get('scheduleEvery', locale)
          .replaceAll('{interval}', _formatDuration(schedule.interval!, locale));
    }
    if (schedule.time != null) {
      final time = '${schedule.time!.hour.toString().padLeft(2, '0')}:${schedule.time!.minute.toString().padLeft(2, '0')}';
      return '${AppLocalizations.get('scheduleAtTime', locale)} $time';
    }
    return AppLocalizations.get('scheduleSync', locale);
  }

  String _formatDuration(Duration dur, String locale) {
    if (dur.inMinutes < 60) return '${dur.inMinutes}m';
    return '${dur.inHours}h';
  }

  String _dayLabel(int day, String locale) {
    const keys = ['', 'monday', 'tuesday', 'wednesday', 'thursday', 'friday', 'saturday', 'sunday'];
    return AppLocalizations.get(keys[day], locale);
  }
}

class _JobStatusInfo {
  final IconData icon;
  final Color color;
  final String label;
  const _JobStatusInfo(this.icon, this.color, this.label);
}
