import 'dart:io';

import 'package:anyware/core/file_picker_helper.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:permission_handler/permission_handler.dart';

import 'package:anyware/core/licensing/feature_gate.dart';
import 'package:anyware/core/licensing/license_service.dart';
import 'package:anyware/core/theme.dart';
import 'package:anyware/features/sync/data/sync_service.dart';
import 'package:anyware/widgets/pro_upgrade_dialog.dart';
import 'package:anyware/features/sync/domain/sync_state.dart';
import 'package:anyware/features/sync/presentation/sync_job_wizard.dart';
import 'package:anyware/features/settings/presentation/providers.dart';
import 'package:anyware/widgets/glassmorphism.dart';
import 'package:anyware/i18n/app_localizations.dart';
import 'package:anyware/widgets/desktop_content_shell.dart';

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
    final isDesktopShell = DesktopShellScope.of(context);

    // Desktop master-detail: show list + detail side by side when wide enough.
    if (isDesktopShell && syncState.activeJobId != null && syncState.selectedJob != null) {
      return DesktopContentShell(
        title: AppLocalizations.get('folderSync', locale),
        actions: [
          IconButton(
            icon: const Icon(Icons.add_rounded),
            tooltip: AppLocalizations.get('newSync', locale),
            onPressed: () => _openWizard(context),
          ),
        ],
        contentPadding: EdgeInsets.zero,
        child: LayoutBuilder(
          builder: (context, constraints) {
            if (constraints.maxWidth > 700) {
              // Master-detail side by side
              return Row(
                children: [
                  SizedBox(
                    width: 340,
                    child: _buildJobListBody(syncState, locale, isDark),
                  ),
                  VerticalDivider(
                    width: 1,
                    thickness: 0.5,
                    color: isDark
                        ? Colors.white.withValues(alpha: 0.06)
                        : AppColors.lightDivider,
                  ),
                  Expanded(
                    child: _buildJobDetailBody(syncState, locale, isDark),
                  ),
                ],
              );
            }
            // Narrow desktop: detail only with back button
            return _buildJobDetailBody(syncState, locale, isDark);
          },
        ),
      );
    }

    // If a job is selected on mobile, show its detail screen.
    if (syncState.activeJobId != null && syncState.selectedJob != null) {
      return _buildJobDetailView(context, syncState, locale, isDark);
    }

    // Otherwise show the job list.
    return _buildJobListView(context, syncState, locale, isDark);
  }

  /// The job list body content (without Scaffold/DesktopContentShell wrapper).
  Widget _buildJobListBody(SyncState syncState, String locale, bool isDark) {
    final syncService = ref.read(syncServiceProvider.notifier);
    final jobs = syncState.jobs;
    final pairedJobIds = syncState.pairings.map((p) => p.jobId).toSet();
    final unpairedSessions = syncState.activeSyncSessions.entries
        .where((e) {
          final parts = e.key.split('::');
          final sessionJobId = parts.length > 1 ? parts[1] : '';
          return sessionJobId.isEmpty || !pairedJobIds.contains(sessionJobId);
        })
        .map((e) => e.value)
        .toList();
    final hasReceiverData = unpairedSessions.isNotEmpty ||
        (syncState.isReceiving && pairedJobIds.isEmpty);

    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      children: [
        if (hasReceiverData) ...[
          _buildReceiverPanel(syncState, locale, isDark, syncService),
          const SizedBox(height: 16),
        ],
        if (syncState.pairings.isNotEmpty) ...[
          _buildPairingsSection(syncState, locale, isDark, syncService),
          const SizedBox(height: 16),
        ],
        _buildReceiverFolderConfig(locale, isDark),
        const SizedBox(height: 16),
        if (jobs.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                const Icon(Icons.upload_rounded, size: 16, color: AppColors.neonBlue),
                const SizedBox(width: 6),
                Text(
                  AppLocalizations.get('syncOutgoing', locale),
                  style: const TextStyle(
                    fontWeight: FontWeight.w600, fontSize: 13,
                    color: AppColors.neonBlue,
                  ),
                ),
                const Spacer(),
                Text(
                  '${jobs.length}',
                  style: const TextStyle(color: Colors.grey, fontSize: 12),
                ),
              ],
            ),
          ),
        ],
        for (final job in jobs) ...[
          _buildJobCard(context, job, locale, isDark, syncService),
          const SizedBox(height: 12),
        ],
        if (syncState.hasConflicts)
          _buildConflictsBanner(syncState, locale, isDark, syncService),
      ],
    );
  }

  /// The job detail body content (without Scaffold/DesktopContentShell wrapper).
  Widget _buildJobDetailBody(SyncState syncState, String locale, bool isDark) {
    final syncService = ref.read(syncServiceProvider.notifier);
    final job = syncState.selectedJob!;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        children: [
          // Back + title bar for detail
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.arrow_back_rounded),
                  onPressed: () => syncService.selectJob(null),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    job.name,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.schedule_rounded, size: 20),
                  tooltip: AppLocalizations.get('scheduleSync', locale),
                  onPressed: () => _showScheduleDialog(context, locale, job, syncService),
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline_rounded, size: 20),
                  tooltip: AppLocalizations.get('deleteSync', locale),
                  onPressed: () => _confirmDeleteJob(context, locale, job, syncService),
                ),
              ],
            ),
          ),
          _buildJobInfoCard(job, locale, isDark),
          const SizedBox(height: 12),
          _buildJobStatusSection(job, locale),
          const SizedBox(height: 12),
          Expanded(child: _buildFileList(job, locale, isDark, syncService)),
          _buildJobActions(job, locale, syncService),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Job List View
  // ═══════════════════════════════════════════════════════════════════════════

  Widget _buildJobListView(
    BuildContext context, SyncState syncState, String locale, bool isDark,
  ) {
    final syncService = ref.read(syncServiceProvider.notifier);
    final jobs = syncState.jobs;
    // Show receiver panel only for sessions NOT linked to a pairing.
    final pairedJobIds = syncState.pairings.map((p) => p.jobId).toSet();
    final unpairedSessions = syncState.activeSyncSessions.entries
        .where((e) {
          // Session key is "deviceId::jobId" — extract jobId.
          final parts = e.key.split('::');
          final sessionJobId = parts.length > 1 ? parts[1] : '';
          return sessionJobId.isEmpty || !pairedJobIds.contains(sessionJobId);
        })
        .map((e) => e.value)
        .toList();
    final hasReceiverData = unpairedSessions.isNotEmpty ||
        (syncState.isReceiving && pairedJobIds.isEmpty);

    final actions = <Widget>[
      IconButton(
        icon: const Icon(Icons.add_rounded),
        tooltip: AppLocalizations.get('newSync', locale),
        onPressed: () => _openWizard(context),
      ),
    ];

    final bodyContent = ListView(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      children: [
        // ── Receiver section (always visible when receiving) ──
        if (hasReceiverData) ...[
          _buildReceiverPanel(syncState, locale, isDark, syncService),
          const SizedBox(height: 16),
        ],

        // ── Pairing cards (accepted sync pairings) ──
        if (syncState.pairings.isNotEmpty) ...[
          _buildPairingsSection(syncState, locale, isDark, syncService),
          const SizedBox(height: 16),
        ],

        // ── Receiver folder config (always visible) ──
        _buildReceiverFolderConfig(locale, isDark),
        const SizedBox(height: 16),

        // ── Empty state when no outgoing jobs and no receiver data ──
        if (jobs.isEmpty && !hasReceiverData) ...[
          const SizedBox(height: 40),
          Center(
            child: Column(
              children: [
                Icon(Icons.sync_rounded, size: 64, color: Colors.grey.shade600),
                const SizedBox(height: 16),
                Text(
                  AppLocalizations.get('noSyncJobs', locale),
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey.shade500, fontSize: 16),
                ),
                const SizedBox(height: 24),
                ElevatedButton.icon(
                  onPressed: () => _openWizard(context),
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
          ),
        ],

        // ── Outgoing jobs header ──
        if (jobs.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                const Icon(Icons.upload_rounded, size: 16, color: AppColors.neonBlue),
                const SizedBox(width: 6),
                Text(
                  AppLocalizations.get('syncOutgoing', locale),
                  style: const TextStyle(
                    fontWeight: FontWeight.w600, fontSize: 13,
                    color: AppColors.neonBlue,
                  ),
                ),
                const Spacer(),
                Text(
                  '${jobs.length}',
                  style: const TextStyle(color: Colors.grey, fontSize: 12),
                ),
              ],
            ),
          ),
        ],

        // Job cards.
        for (final job in jobs) ...[
          _buildJobCard(context, job, locale, isDark, syncService),
          const SizedBox(height: 12),
        ],

        // Pending conflicts banner.
        if (syncState.hasConflicts)
          _buildConflictsBanner(syncState, locale, isDark, syncService),
      ],
    );

    if (DesktopShellScope.of(context)) {
      return DesktopContentShell(
        title: AppLocalizations.get('folderSync', locale),
        actions: actions,
        child: bodyContent,
      );
    }

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: Text(AppLocalizations.get('folderSync', locale)),
        backgroundColor: Colors.transparent,
        automaticallyImplyLeading: false,
        actions: actions,
      ),
      body: bodyContent,
    );
  }

  void _openWizard(BuildContext context) {
    final licenseInfo = ref.read(licenseServiceProvider);
    final syncState = ref.read(syncServiceProvider);
    final jobCount = syncState.jobs.length;

    if (!FeatureGate.canCreateSyncJob(licenseInfo.plan, jobCount)) {
      final locale = ref.read(settingsProvider).locale;
      showProUpgradeDialog(context, ProFeature.unlimitedSync, locale);
      return;
    }

    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const SyncJobWizard()),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Job Card (Enhanced)
  // ═══════════════════════════════════════════════════════════════════════════

  Widget _buildJobCard(
    BuildContext context, SyncJob job, String locale, bool isDark,
    SyncService syncService,
  ) {
    final statusInfo = _jobStatusInfo(job, locale);
    final filterCount = job.includePatterns.length + job.excludePatterns.length;

    return GestureDetector(
      onSecondaryTapUp: (details) {
        _showJobContextMenu(
          context, details.globalPosition, job, locale, syncService,
        );
      },
      child: GlassmorphismCard(
        borderRadius: 16,
        padding: const EdgeInsets.all(16),
        onTap: () => syncService.selectJob(job.id),
        child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header: name + badges + phase icon.
              Row(
                children: [
                  Expanded(
                    child: Row(
                      children: [
                        Flexible(
                          child: Text(
                            job.name,
                            style: const TextStyle(
                              fontWeight: FontWeight.bold, fontSize: 16,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 8),
                        // Direction badge.
                        _directionBadge(job),
                        const SizedBox(width: 4),
                        // Mode badge (photo/video).
                        if (job.isPhotoMode) _modeBadge(locale),
                      ],
                    ),
                  ),
                  _phaseIcon(job.phase),
                ],
              ),
              const SizedBox(height: 8),

              // Source → Target with direction arrow.
              Row(
                children: [
                  const Icon(Icons.folder_rounded, size: 14, color: Colors.grey),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      '${_shortenPath(job.sourceDirectory)}  ${job.directionArrow}  ${job.targetDeviceName}',
                      style: const TextStyle(color: Colors.grey, fontSize: 12),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),

              // Status text + last sync time.
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
                  // Filter count badge.
                  if (filterCount > 0)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                      decoration: BoxDecoration(
                        color: Colors.grey.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.filter_alt_outlined, size: 10, color: Colors.grey),
                          const SizedBox(width: 2),
                          Text('$filterCount', style: const TextStyle(fontSize: 10, color: Colors.grey)),
                        ],
                      ),
                    ),
                ],
              ),

              // NeonProgressBar (when syncing).
              if (job.phase == SyncJobPhase.syncing && job.totalBytes > 0) ...[
                const SizedBox(height: 10),
                NeonProgressBar(
                  progress: job.progress,
                  color: AppColors.neonBlue,
                  height: 5,
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

              // Last sync time (when idle and has previous sync).
              if (job.phase == SyncJobPhase.idle && job.lastSyncTime != null) ...[
                const SizedBox(height: 6),
                Row(
                  children: [
                    const Icon(Icons.access_time_rounded, size: 12, color: Colors.grey),
                    const SizedBox(width: 4),
                    Text(
                      _formatRelativeTime(job.lastSyncTime!, locale),
                      style: const TextStyle(color: Colors.grey, fontSize: 11),
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
      ),
    );
  }

  /// Right-click context menu for sync job cards.
  void _showJobContextMenu(
    BuildContext context,
    Offset position,
    SyncJob job,
    String locale,
    SyncService syncService,
  ) {
    final items = <PopupMenuEntry<String>>[];

    if (job.phase == SyncJobPhase.idle || job.phase == SyncJobPhase.error) {
      items.add(PopupMenuItem(
        value: 'start',
        child: ListTile(
          dense: true,
          leading: const Icon(Icons.play_arrow_rounded, size: 20),
          title: Text(AppLocalizations.get('syncNow', locale)),
        ),
      ));
    }
    if (job.phase == SyncJobPhase.syncing) {
      items.add(PopupMenuItem(
        value: 'pause',
        child: ListTile(
          dense: true,
          leading: const Icon(Icons.pause_rounded, size: 20),
          title: Text(AppLocalizations.get('pause', locale)),
        ),
      ));
    }
    if (job.phase == SyncJobPhase.paused) {
      items.add(PopupMenuItem(
        value: 'resume',
        child: ListTile(
          dense: true,
          leading: const Icon(Icons.play_arrow_rounded, size: 20),
          title: Text(AppLocalizations.get('resume', locale)),
        ),
      ));
    }
    if (job.isActive) {
      items.add(PopupMenuItem(
        value: 'stop',
        child: ListTile(
          dense: true,
          leading: Icon(Icons.stop_rounded, size: 20, color: Colors.red.shade300),
          title: Text(AppLocalizations.get('stop', locale)),
        ),
      ));
    }

    items.add(const PopupMenuDivider());

    items.add(PopupMenuItem(
      value: 'open',
      child: ListTile(
        dense: true,
        leading: const Icon(Icons.folder_open_rounded, size: 20),
        title: Text(AppLocalizations.get('openFolder', locale)),
      ),
    ));

    items.add(PopupMenuItem(
      value: 'delete',
      child: ListTile(
        dense: true,
        leading: Icon(Icons.delete_outline_rounded, size: 20, color: Colors.red.shade300),
        title: Text(AppLocalizations.get('deleteSync', locale),
            style: TextStyle(color: Colors.red.shade300)),
      ),
    ));

    showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx, position.dy, position.dx, position.dy,
      ),
      items: items,
    ).then((value) {
      if (value == null) return;
      switch (value) {
        case 'start':
          syncService.startJob(job.id);
        case 'pause':
          syncService.pauseJob(job.id);
        case 'resume':
          syncService.resumeJob(job.id);
        case 'stop':
          syncService.stopJob(job.id);
        case 'open':
          _openSyncFolder(job.sourceDirectory);
        case 'delete':
          _confirmDeleteJob(context, locale, job, syncService);
      }
    });
  }

  Widget _directionBadge(SyncJob job) {
    final isBidi = job.isBidirectional;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: (isBidi ? AppColors.neonGreen : AppColors.neonBlue).withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Icon(
        isBidi ? Icons.swap_horiz : Icons.arrow_forward,
        size: 14,
        color: isBidi ? AppColors.neonGreen : AppColors.neonBlue,
      ),
    );
  }

  Widget _modeBadge(String locale) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: Colors.amber.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(6),
      ),
      child: const Icon(Icons.photo_camera, size: 12, color: Colors.amber),
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
  // Job Detail View (Enhanced)
  // ═══════════════════════════════════════════════════════════════════════════

  Widget _buildJobDetailView(
    BuildContext context, SyncState syncState, String locale, bool isDark,
  ) {
    final syncService = ref.read(syncServiceProvider.notifier);
    final job = syncState.selectedJob!;

    final detailActions = <Widget>[
      IconButton(
        icon: const Icon(Icons.arrow_back_rounded),
        onPressed: () => syncService.selectJob(null),
      ),
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
    ];

    final detailBody = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        children: [
          // Info card (with sync config details).
          _buildJobInfoCard(job, locale, isDark),
          const SizedBox(height: 12),

          // Status section.
          _buildJobStatusSection(job, locale),
          const SizedBox(height: 12),

          // File list with section headers.
          Expanded(child: _buildFileList(job, locale, isDark, syncService)),

          // Action bar.
          _buildJobActions(job, locale, syncService),
          const SizedBox(height: 16),
        ],
      ),
    );

    if (DesktopShellScope.of(context)) {
      return DesktopContentShell(
        title: job.name,
        actions: detailActions,
        contentPadding: EdgeInsets.zero,
        child: detailBody,
      );
    }

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
      body: detailBody,
    );
  }

  Widget _buildJobInfoCard(SyncJob job, String locale, bool isDark) {
    return GlassmorphismCard(
      borderRadius: 12,
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Source folder.
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

          // Target device.
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
          const SizedBox(height: 8),

          // Sync config badges row.
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              // Direction badge.
              _configChip(
                icon: job.isBidirectional ? Icons.swap_horiz : Icons.arrow_forward,
                label: AppLocalizations.get(
                  job.isBidirectional ? 'syncBidirectional' : 'syncOneWay',
                  locale,
                ),
                color: job.isBidirectional ? AppColors.neonGreen : AppColors.neonBlue,
              ),
              // Conflict strategy badge.
              _configChip(
                icon: Icons.merge_type,
                label: AppLocalizations.get(
                  _conflictStrategyKey(job.conflictStrategy),
                  locale,
                ),
                color: Colors.orange,
              ),
              // Mode badge.
              if (job.isPhotoMode)
                _configChip(
                  icon: Icons.photo_camera,
                  label: AppLocalizations.get('syncModePhotoVideo', locale),
                  color: Colors.amber,
                ),
              // Mirror deletions.
              if (job.mirrorDeletions)
                _configChip(
                  icon: Icons.delete_sweep,
                  label: AppLocalizations.get('mirrorDeletions', locale),
                  color: Colors.red.shade300,
                ),
              // Filter count.
              if (job.includePatterns.isNotEmpty || job.excludePatterns.isNotEmpty)
                _configChip(
                  icon: Icons.filter_alt,
                  label: '${job.includePatterns.length + job.excludePatterns.length} ${AppLocalizations.get('syncFilters', locale)}',
                  color: Colors.purple.shade300,
                ),
            ],
          ),

          // Schedule.
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

  Widget _configChip({required IconData icon, required String label, required Color color}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 4),
          Text(label, style: TextStyle(fontSize: 10, color: color, fontWeight: FontWeight.w500)),
        ],
      ),
    );
  }

  String _conflictStrategyKey(ConflictStrategy strategy) {
    switch (strategy) {
      case ConflictStrategy.newerWins:
        return 'conflictNewerWins';
      case ConflictStrategy.askUser:
        return 'conflictAskUser';
      case ConflictStrategy.keepBoth:
        return 'conflictKeepBoth';
    }
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

    // Group files by status for section headers.
    final syncing = items.where((i) => i.status == SyncFileStatus.syncing).toList();
    final pending = items.where((i) => i.status == SyncFileStatus.pending).toList();
    final completed = items.where((i) => i.status == SyncFileStatus.completed).toList();
    final failed = items.where((i) => i.status == SyncFileStatus.failed).toList();
    final skipped = items.where((i) => i.status == SyncFileStatus.skipped || i.status == SyncFileStatus.paused).toList();

    final sections = <_FileSection>[];
    if (syncing.isNotEmpty) sections.add(_FileSection(AppLocalizations.get('syncing', locale), syncing, AppColors.neonBlue));
    if (pending.isNotEmpty) sections.add(_FileSection(AppLocalizations.get('pending', locale), pending, Colors.grey));
    if (failed.isNotEmpty) sections.add(_FileSection(AppLocalizations.get('failed', locale), failed, Colors.red));
    if (completed.isNotEmpty) sections.add(_FileSection(AppLocalizations.get('completed', locale), completed, AppColors.neonGreen));
    if (skipped.isNotEmpty) sections.add(_FileSection(AppLocalizations.get('syncFileSkipped', locale), skipped, Colors.grey));

    return ListView.builder(
      controller: _fileListController,
      itemCount: sections.fold<int>(0, (sum, s) => sum + 1 + s.items.length),
      itemBuilder: (context, index) {
        // Map flat index to section + item.
        int remaining = index;
        for (final section in sections) {
          if (remaining == 0) {
            // Section header.
            return Padding(
              padding: const EdgeInsets.only(top: 8, bottom: 4),
              child: Row(
                children: [
                  Container(
                    width: 3, height: 14,
                    decoration: BoxDecoration(
                      color: section.color,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '${section.label} (${section.items.length})',
                    style: TextStyle(
                      fontSize: 11, fontWeight: FontWeight.w600,
                      color: section.color,
                    ),
                  ),
                ],
              ),
            );
          }
          remaining--;
          if (remaining < section.items.length) {
            return _buildFileRow(section.items[remaining], syncService, job, locale);
          }
          remaining -= section.items.length;
        }
        return const SizedBox.shrink();
      },
    );
  }

  Widget _buildFileRow(SyncFileItem item, SyncService syncService, SyncJob job, String locale) {
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
              onPressed: () {
                final idx = job.fileItems.indexOf(item);
                if (idx >= 0) syncService.skipFile(job.id, idx);
              },
              tooltip: AppLocalizations.get('skipFile', locale),
            ),
        ],
      ),
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
        if (job.phase == SyncJobPhase.syncing ||
            job.phase == SyncJobPhase.watching)
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
  // Conflict Resolution
  // ═══════════════════════════════════════════════════════════════════════════

  Widget _buildConflictsBanner(
    SyncState syncState, String locale, bool isDark, SyncService syncService,
  ) {
    final unresolvedCount =
        syncState.pendingConflicts.where((c) => !c.isResolved).length;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: GlassmorphismCard(
        borderRadius: 12,
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.warning_amber_rounded, color: Colors.orange.shade400, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${AppLocalizations.get('syncConflicts', locale)} ($unresolvedCount)',
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                      color: Colors.orange.shade400,
                    ),
                  ),
                ),
                // Resolve all button.
                TextButton.icon(
                  onPressed: () => _showConflictDialog(context, syncState, locale, syncService),
                  icon: const Icon(Icons.merge_type, size: 16),
                  label: Text(AppLocalizations.get('syncResolveConflicts', locale)),
                  style: TextButton.styleFrom(
                    foregroundColor: Colors.orange.shade400,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            // List first 3 conflict paths.
            for (final conflict in syncState.pendingConflicts.where((c) => !c.isResolved).take(3))
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  children: [
                    Icon(Icons.description_outlined, size: 14, color: Colors.orange.shade300),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        conflict.relativePath,
                        style: const TextStyle(fontSize: 12),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    // Quick action buttons.
                    _miniConflictButton(
                      Icons.phone_android,
                      AppLocalizations.get('syncKeepLocal', locale),
                      () => syncService.resolveConflict(conflict.relativePath, 'local'),
                    ),
                    const SizedBox(width: 4),
                    _miniConflictButton(
                      Icons.cloud,
                      AppLocalizations.get('syncKeepRemote', locale),
                      () => syncService.resolveConflict(conflict.relativePath, 'remote'),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _miniConflictButton(IconData icon, String tooltip, VoidCallback onTap) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Container(
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: Colors.orange.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Icon(icon, size: 14, color: Colors.orange),
        ),
      ),
    );
  }

  void _showConflictDialog(
    BuildContext context, SyncState syncState, String locale, SyncService syncService,
  ) {
    showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            final conflicts = syncState.pendingConflicts;
            return AlertDialog(
              title: Row(
                children: [
                  const Icon(Icons.warning_amber_rounded, color: Colors.orange),
                  const SizedBox(width: 8),
                  Text(AppLocalizations.get('syncConflicts', locale)),
                ],
              ),
              content: SizedBox(
                width: 420,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Bulk actions.
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: () {
                              syncService.resolveAllConflicts('local');
                              Navigator.of(ctx).pop();
                            },
                            icon: const Icon(Icons.phone_android, size: 16),
                            label: Text(AppLocalizations.get('syncKeepAllLocal', locale)),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: () {
                              syncService.resolveAllConflicts('remote');
                              Navigator.of(ctx).pop();
                            },
                            icon: const Icon(Icons.cloud, size: 16),
                            label: Text(AppLocalizations.get('syncKeepAllRemote', locale)),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    const Divider(height: 1),
                    const SizedBox(height: 8),

                    // Per-file conflict list.
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 300),
                      child: ListView.builder(
                        shrinkWrap: true,
                        itemCount: conflicts.length,
                        itemBuilder: (_, i) {
                          final c = conflicts[i];
                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 6),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  c.relativePath,
                                  style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 13),
                                  overflow: TextOverflow.ellipsis,
                                ),
                                const SizedBox(height: 4),
                                Row(
                                  children: [
                                    // Local info.
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            AppLocalizations.get('syncKeepLocal', locale),
                                            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
                                          ),
                                          Text(
                                            '${_formatBytes(c.localSize)} · ${_formatTime(c.localModified)}',
                                            style: const TextStyle(fontSize: 10, color: Colors.grey),
                                          ),
                                        ],
                                      ),
                                    ),
                                    // Remote info.
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            AppLocalizations.get('syncKeepRemote', locale),
                                            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
                                          ),
                                          Text(
                                            '${_formatBytes(c.remoteSize)} · ${_formatTime(c.remoteModified)}',
                                            style: const TextStyle(fontSize: 10, color: Colors.grey),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 4),
                                // Per-file resolution buttons.
                                Row(
                                  children: [
                                    _conflictResolutionChip(
                                      AppLocalizations.get('syncKeepLocal', locale),
                                      c.resolution == 'local',
                                      () => syncService.resolveConflict(c.relativePath, 'local'),
                                    ),
                                    const SizedBox(width: 6),
                                    _conflictResolutionChip(
                                      AppLocalizations.get('syncKeepRemote', locale),
                                      c.resolution == 'remote',
                                      () => syncService.resolveConflict(c.relativePath, 'remote'),
                                    ),
                                    const SizedBox(width: 6),
                                    _conflictResolutionChip(
                                      AppLocalizations.get('syncKeepBoth', locale),
                                      c.resolution == 'both',
                                      () => syncService.resolveConflict(c.relativePath, 'both'),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: Text(AppLocalizations.get('close', locale)),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _conflictResolutionChip(String label, bool selected, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: selected
              ? AppColors.neonBlue.withValues(alpha: 0.15)
              : Colors.grey.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(8),
          border: selected
              ? Border.all(color: AppColors.neonBlue.withValues(alpha: 0.5))
              : null,
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
            color: selected ? AppColors.neonBlue : Colors.grey,
          ),
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Receiver Panel (Incoming sync sessions)
  // ═══════════════════════════════════════════════════════════════════════════

  /// Full receiver panel showing incoming sync sessions with progress,
  /// file counts, sender info, and controls.
  Widget _buildReceiverPanel(
    SyncState syncState, String locale, bool isDark, SyncService syncService,
  ) {
    final sessions = syncState.activeSyncSessions.values.toList();
    final activeSessions = sessions.where((s) => s.isActive).toList();
    final completedSessions = sessions.where((s) => !s.isActive).toList();
    final syncFolder = syncService.getSyncReceiveFolder();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Header: "Incoming Sync" with session count and clear button.
        Row(
          children: [
            const Icon(Icons.download_rounded, size: 16, color: AppColors.neonGreen),
            const SizedBox(width: 6),
            Text(
              AppLocalizations.get('syncIncoming', locale),
              style: const TextStyle(
                fontWeight: FontWeight.w600, fontSize: 13,
                color: AppColors.neonGreen,
              ),
            ),
            if (activeSessions.isNotEmpty) ...[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: AppColors.neonGreen.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(
                      width: 10, height: 10,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.5, color: AppColors.neonGreen,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      '${activeSessions.length}',
                      style: const TextStyle(
                        fontSize: 11, color: AppColors.neonGreen,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const Spacer(),
            if (completedSessions.isNotEmpty)
              TextButton.icon(
                onPressed: () => syncService.clearCompletedReceiverSessions(),
                icon: const Icon(Icons.clear_all_rounded, size: 16),
                label: Text(AppLocalizations.get('clearCompleted', locale)),
                style: TextButton.styleFrom(
                  foregroundColor: Colors.grey,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  textStyle: const TextStyle(fontSize: 11),
                ),
              ),
          ],
        ),
        const SizedBox(height: 4),

        // Sync receive folder info.
        Row(
          children: [
            const Icon(Icons.folder_outlined, size: 13, color: Colors.grey),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                '→ $syncFolder',
                style: const TextStyle(color: Colors.grey, fontSize: 11),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),

        // Active sessions — grouped by sender for clarity.
        for (final session in activeSessions) ...[
          _buildReceiverSessionCard(session, locale, isDark, isActive: true),
          const SizedBox(height: 8),
        ],

        // Completed sessions.
        if (completedSessions.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              AppLocalizations.get('syncCompletedSessions', locale),
              style: TextStyle(
                fontSize: 11, color: Colors.grey.shade500,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          for (final session in completedSessions) ...[
            _buildReceiverSessionCard(session, locale, isDark, isActive: false),
            const SizedBox(height: 8),
          ],
        ],
      ],
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Pairings Section
  // ═══════════════════════════════════════════════════════════════════════════

  Widget _buildPairingsSection(
    SyncState syncState, String locale, bool isDark, SyncService syncService,
  ) {
    final pairings = syncState.pairings;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.link_rounded, size: 16, color: AppColors.neonPurple),
            const SizedBox(width: 6),
            Text(
              AppLocalizations.get('syncPairings', locale),
              style: const TextStyle(
                fontWeight: FontWeight.w600, fontSize: 13,
                color: AppColors.neonPurple,
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: AppColors.neonPurple.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                '${pairings.length}',
                style: const TextStyle(
                  fontSize: 11, color: AppColors.neonPurple,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),

        for (final pairing in pairings) ...[
          _buildPairingCard(pairing, syncState, locale, isDark, syncService),
          const SizedBox(height: 8),
        ],
      ],
    );
  }

  Widget _buildPairingCard(
    SyncPairing pairing, SyncState syncState,
    String locale, bool isDark, SyncService syncService,
  ) {
    final sessionKey = '${pairing.senderDeviceId}::${pairing.jobId}';
    final session = syncState.activeSyncSessions[sessionKey];
    final isActive = session?.isActive ?? false;
    final hasSession = session != null;

    final directionIcon = pairing.direction == SyncDirection.bidirectional
        ? Icons.sync_rounded
        : Icons.arrow_downward_rounded;

    // Shortened folder path (last 2 segments).
    final folderShort = _shortenPath(pairing.receiveFolder);

    return GestureDetector(
      onTap: () => _showPairingDetail(pairing, session, locale, syncService),
      child: GlassmorphismCard(
        borderRadius: 12,
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header: direction icon + name + status + menu
            Row(
              children: [
                Icon(directionIcon, size: 18, color: AppColors.neonPurple),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    pairing.jobName,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 14,
                    ),
                  ),
                ),
                if (isActive)
                  const SizedBox(
                    width: 14, height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.5, color: AppColors.neonGreen,
                    ),
                  )
                else if (hasSession && !session.isActive)
                  const Icon(Icons.check_circle, size: 16,
                      color: AppColors.neonGreen),
                PopupMenuButton<String>(
                  icon: const Icon(Icons.more_vert, size: 18),
                  padding: EdgeInsets.zero,
                  itemBuilder: (ctx) => [
                    PopupMenuItem(
                      value: 'detail',
                      child: Row(
                        children: [
                          const Icon(Icons.info_outline, size: 16),
                          const SizedBox(width: 8),
                          Text(AppLocalizations.get('syncDetailTitle', locale)),
                        ],
                      ),
                    ),
                    PopupMenuItem(
                      value: 'folder',
                      child: Row(
                        children: [
                          const Icon(Icons.folder_open, size: 16),
                          const SizedBox(width: 8),
                          Text(AppLocalizations.get('openFolder', locale)),
                        ],
                      ),
                    ),
                    PopupMenuItem(
                      value: 'remove',
                      child: Row(
                        children: [
                          const Icon(Icons.link_off, size: 16, color: Colors.red),
                          const SizedBox(width: 8),
                          Text(
                            AppLocalizations.get('syncRemovePairing', locale),
                            style: const TextStyle(color: Colors.red),
                          ),
                        ],
                      ),
                    ),
                  ],
                  onSelected: (value) {
                    if (value == 'detail') {
                      _showPairingDetail(pairing, session, locale, syncService);
                    } else if (value == 'folder') {
                      _openSyncFolder(pairing.receiveFolder);
                    } else if (value == 'remove') {
                      _confirmRemovePairing(pairing, locale, syncService);
                    }
                  },
                ),
              ],
            ),
            const SizedBox(height: 6),

            // Sender + folder row
            Row(
              children: [
                const Icon(Icons.phone_android_rounded, size: 14,
                    color: Colors.grey),
                const SizedBox(width: 4),
                Text(
                  pairing.senderDeviceName,
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
                const SizedBox(width: 12),
                const Icon(Icons.folder_outlined, size: 14, color: Colors.grey),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    folderShort,
                    style: const TextStyle(fontSize: 11, color: Colors.grey),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),

            // Last sync time + stats OR active session
            const SizedBox(height: 6),
            if (isActive && hasSession) ...[
              Row(
                children: [
                  const Icon(Icons.download_rounded, size: 14,
                      color: AppColors.neonGreen),
                  const SizedBox(width: 6),
                  Text(
                    '${session.receivedItems.length} '
                    '${AppLocalizations.get("syncReceivedFiles", locale)} · '
                    '${_formatBytes(session.receivedBytes)}',
                    style: const TextStyle(
                      fontSize: 11, color: AppColors.neonGreen,
                    ),
                  ),
                ],
              ),
            ] else ...[
              Row(
                children: [
                  if (pairing.lastSyncTime != null) ...[
                    const Icon(Icons.access_time, size: 13, color: Colors.grey),
                    const SizedBox(width: 4),
                    Text(
                      _formatRelativeTime(pairing.lastSyncTime!, locale),
                      style: const TextStyle(fontSize: 11, color: Colors.grey),
                    ),
                    const SizedBox(width: 10),
                  ],
                  if (pairing.lastSyncFileCount > 0) ...[
                    const Icon(Icons.description_outlined, size: 13,
                        color: Colors.grey),
                    const SizedBox(width: 3),
                    Text(
                      '${pairing.lastSyncFileCount} '
                      '${AppLocalizations.get("syncReceivedFiles", locale)}',
                      style: const TextStyle(fontSize: 11, color: Colors.grey),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _formatBytes(pairing.lastSyncTotalBytes),
                      style: const TextStyle(fontSize: 11, color: Colors.grey),
                    ),
                  ],
                  if (pairing.lastSyncTime == null &&
                      pairing.lastSyncFileCount == 0)
                    Text(
                      AppLocalizations.get('syncWaiting', locale),
                      style: const TextStyle(
                          fontSize: 11, color: Colors.grey),
                    ),
                  const Spacer(),
                  const Icon(Icons.chevron_right, size: 16,
                      color: Colors.grey),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Opens the receive folder in the platform file manager.
  void _openSyncFolder(String folderPath) {
    try {
      if (Platform.isWindows) {
        Process.run('explorer', [folderPath]);
      } else if (Platform.isMacOS) {
        Process.run('open', [folderPath]);
      } else if (Platform.isLinux) {
        Process.run('xdg-open', [folderPath]);
      } else if (Platform.isAndroid) {
        const channel = MethodChannel('com.lifeos.anyware/platform');
        channel.invokeMethod('openFolder', {'path': folderPath});
      }
    } catch (_) {}
  }

  /// Shortens a folder path to show only the last 2 segments.
  String _shortenPath(String fullPath) {
    final parts = p.split(fullPath);
    if (parts.length <= 2) return fullPath;
    return p.joinAll(['...', ...parts.sublist(parts.length - 2)]);
  }

  /// Shows a detail bottom sheet for a pairing.
  void _showPairingDetail(
    SyncPairing pairing, ReceiverSyncSession? session,
    String locale, SyncService syncService,
  ) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        final items = session?.receivedItems ?? [];
        final dirLabel = pairing.direction == SyncDirection.bidirectional
            ? AppLocalizations.get('syncDirection_bidirectional', locale)
            : AppLocalizations.get('syncDirection_oneWay', locale);

        return DraggableScrollableSheet(
          initialChildSize: 0.65,
          minChildSize: 0.3,
          maxChildSize: 0.9,
          expand: false,
          builder: (ctx, scrollController) => Column(
            children: [
              // Handle bar
              Container(
                margin: const EdgeInsets.only(top: 8, bottom: 4),
                width: 40, height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey.shade400,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              // Title
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(
                  children: [
                    const Icon(Icons.link_rounded, size: 20,
                        color: AppColors.neonPurple),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        pairing.jobName,
                        style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 16,
                        ),
                      ),
                    ),
                    // Open folder button
                    IconButton(
                      icon: const Icon(Icons.folder_open, size: 20),
                      tooltip: AppLocalizations.get('openFolder', locale),
                      onPressed: () => _openSyncFolder(pairing.receiveFolder),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                    ),
                  ],
                ),
              ),

              // Info section
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Column(
                  children: [
                    // Sender device
                    _pairingInfoRow(
                      Icons.phone_android_rounded,
                      pairing.senderDeviceName,
                    ),
                    const SizedBox(height: 4),
                    // Folder path
                    _pairingInfoRow(
                      Icons.folder_outlined,
                      pairing.receiveFolder,
                    ),
                    const SizedBox(height: 4),
                    // Direction + accepted date
                    Row(
                      children: [
                        _pairingChip(
                          pairing.direction == SyncDirection.bidirectional
                              ? Icons.sync_rounded
                              : Icons.arrow_downward_rounded,
                          dirLabel,
                          AppColors.neonPurple,
                        ),
                        const SizedBox(width: 8),
                        _pairingChip(
                          Icons.calendar_today_outlined,
                          _formatDate(pairing.acceptedAt),
                          Colors.grey,
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    // Last sync stats
                    if (pairing.lastSyncTime != null)
                      Row(
                        children: [
                          _pairingChip(
                            Icons.access_time,
                            _formatRelativeTime(pairing.lastSyncTime!, locale),
                            AppColors.neonGreen,
                          ),
                          const SizedBox(width: 8),
                          _pairingChip(
                            Icons.description_outlined,
                            '${pairing.lastSyncFileCount} '
                            '${AppLocalizations.get("syncReceivedFiles", locale)}',
                            Colors.grey,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            _formatBytes(pairing.lastSyncTotalBytes),
                            style: const TextStyle(
                                fontSize: 11, color: Colors.grey),
                          ),
                        ],
                      ),
                  ],
                ),
              ),

              const Divider(height: 16),

              // Session file count header
              if (items.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: [
                      Text(
                        '${items.length} ${AppLocalizations.get("syncReceivedFiles", locale)}',
                        style: const TextStyle(
                          fontSize: 12, fontWeight: FontWeight.w600,
                        ),
                      ),
                      const Spacer(),
                      if (session != null)
                        Text(
                          _formatBytes(session.receivedBytes),
                          style: const TextStyle(
                              fontSize: 11, color: Colors.grey),
                        ),
                    ],
                  ),
                ),

              const SizedBox(height: 4),

              // File list
              Expanded(
                child: items.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.hourglass_empty,
                                size: 32, color: Colors.grey),
                            const SizedBox(height: 8),
                            Text(
                              AppLocalizations.get('syncWaiting', locale),
                              style: const TextStyle(color: Colors.grey),
                            ),
                          ],
                        ),
                      )
                    : ListView.builder(
                        controller: scrollController,
                        itemCount: items.length,
                        itemBuilder: (ctx, i) {
                          final item = items[i];
                          return ListTile(
                            dense: true,
                            leading: _fileStatusIcon(item.status),
                            title: Text(
                              item.relativePath,
                              style: const TextStyle(fontSize: 12),
                              overflow: TextOverflow.ellipsis,
                            ),
                            trailing: Text(
                              _formatBytes(item.fileSize),
                              style: const TextStyle(
                                  fontSize: 11, color: Colors.grey),
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _pairingInfoRow(IconData icon, String text) {
    return Row(
      children: [
        Icon(icon, size: 13, color: Colors.grey),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(fontSize: 11, color: Colors.grey),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }

  Widget _pairingChip(IconData icon, String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 4),
          Text(label, style: TextStyle(fontSize: 10, color: color)),
        ],
      ),
    );
  }

  String _formatDate(DateTime dt) {
    return '${dt.day.toString().padLeft(2, '0')}.'
        '${dt.month.toString().padLeft(2, '0')}.'
        '${dt.year}';
  }

  void _confirmRemovePairing(
    SyncPairing pairing, String locale, SyncService syncService,
  ) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(AppLocalizations.get('syncRemovePairing', locale)),
        content: Text(
          AppLocalizations.format(
            'syncPairingRemoveConfirm', locale,
            {'name': pairing.jobName, 'device': pairing.senderDeviceName},
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(AppLocalizations.get('cancel', locale)),
          ),
          FilledButton(
            onPressed: () {
              syncService.removePairing(pairing.jobId);
              Navigator.of(ctx).pop();
            },
            style: FilledButton.styleFrom(
              backgroundColor: Colors.red,
            ),
            child: Text(AppLocalizations.get('syncRemovePairing', locale)),
          ),
        ],
      ),
    );
  }

  /// Card for a single receiver sync session (active or completed).
  /// Shows per-job info when [session.jobName] is available (new protocol).
  Widget _buildReceiverSessionCard(
    ReceiverSyncSession session, String locale, bool isDark,
    {required bool isActive}
  ) {
    final fileCount = session.receivedItems.length;
    final totalSize = session.receivedBytes;
    final hasJobInfo = session.jobName != null && session.jobName!.isNotEmpty;

    return GlassmorphismCard(
      borderRadius: 12,
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header: sender name + job badge + status indicator.
          Row(
            children: [
              Icon(
                isActive ? Icons.sync_rounded : Icons.check_circle_rounded,
                size: 16,
                color: isActive ? AppColors.neonGreen : Colors.grey,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      session.senderName,
                      style: TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 13,
                        color: isActive ? null : Colors.grey,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (hasJobInfo) ...[
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          Icon(
                            Icons.folder_rounded,
                            size: 12,
                            color: AppColors.neonBlue.withValues(alpha: 0.7),
                          ),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              session.jobName!,
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w500,
                                color: AppColors.neonBlue.withValues(alpha: 0.9),
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              if (isActive)
                const SizedBox(
                  width: 14, height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2, color: AppColors.neonGreen,
                  ),
                )
              else
                Text(
                  AppLocalizations.get('syncCompleted', locale),
                  style: const TextStyle(color: Colors.grey, fontSize: 11),
                ),
            ],
          ),
          const SizedBox(height: 8),

          // Stats row: file count + total size + elapsed time.
          Row(
            children: [
              const Icon(Icons.insert_drive_file_outlined, size: 12, color: Colors.grey),
              const SizedBox(width: 4),
              Text(
                '$fileCount ${AppLocalizations.get('syncFiles', locale)}',
                style: const TextStyle(color: Colors.grey, fontSize: 11),
              ),
              const SizedBox(width: 12),
              const Icon(Icons.data_usage_rounded, size: 12, color: Colors.grey),
              const SizedBox(width: 4),
              Text(
                _formatBytes(totalSize),
                style: const TextStyle(color: Colors.grey, fontSize: 11),
              ),
              const SizedBox(width: 12),
              const Icon(Icons.access_time_rounded, size: 12, color: Colors.grey),
              const SizedBox(width: 4),
              Text(
                _formatRelativeTime(session.startedAt, locale),
                style: const TextStyle(color: Colors.grey, fontSize: 11),
              ),
            ],
          ),

          // Recent files (last 5).
          if (session.receivedItems.isNotEmpty) ...[
            const SizedBox(height: 8),
            const Divider(height: 1),
            const SizedBox(height: 6),
            ...session.receivedItems.reversed.take(5).map((item) =>
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Row(
                  children: [
                    _fileStatusIcon(item.status),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        item.relativePath,
                        style: const TextStyle(fontSize: 11),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Text(
                      _formatBytes(item.fileSize),
                      style: const TextStyle(color: Colors.grey, fontSize: 10),
                    ),
                  ],
                ),
              ),
            ),
            if (fileCount > 5) ...[
              const SizedBox(height: 4),
              Text(
                '+${fileCount - 5} ${AppLocalizations.get('syncMoreFiles', locale)}',
                style: const TextStyle(color: Colors.grey, fontSize: 10),
              ),
            ],
          ],
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Receiver Folder Configuration
  // ═══════════════════════════════════════════════════════════════════════════

  /// Shows the current sync receive folder with a "Change" button.
  Widget _buildReceiverFolderConfig(String locale, bool isDark) {
    final settings = ref.watch(settingsProvider);
    final syncService = ref.read(syncServiceProvider.notifier);
    final currentFolder = syncService.getSyncReceiveFolder();

    return GlassmorphismCard(
      borderRadius: 12,
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          const Icon(Icons.folder_special_rounded, size: 20, color: AppColors.neonBlue),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  AppLocalizations.get('syncReceiveFolder', locale),
                  style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12),
                ),
                const SizedBox(height: 2),
                Text(
                  settings.syncReceiveFolder.isNotEmpty
                      ? settings.syncReceiveFolder
                      : '${AppLocalizations.get('syncReceiveFolderDefault', locale)}: $currentFolder',
                  style: const TextStyle(color: Colors.grey, fontSize: 11),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 2,
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (settings.syncReceiveFolder.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.close_rounded, size: 16),
              tooltip: AppLocalizations.get('syncResetFolder', locale),
              constraints: const BoxConstraints(minWidth: 32),
              padding: EdgeInsets.zero,
              onPressed: () {
                ref.read(settingsProvider.notifier).updateSyncReceiveFolder('');
              },
            ),
          IconButton(
            icon: const Icon(Icons.edit_rounded, size: 16),
            tooltip: AppLocalizations.get('syncChangeFolder', locale),
            constraints: const BoxConstraints(minWidth: 32),
            padding: EdgeInsets.zero,
            onPressed: () => _pickSyncReceiveFolder(context),
          ),
        ],
      ),
    );
  }

  Future<void> _pickSyncReceiveFolder(BuildContext context) async {
    try {
      if (Platform.isAndroid) {
        await Permission.manageExternalStorage.request();
      }
      final result = await FilePickerHelper.getDirectoryPath();
      if (result != null && result.isNotEmpty) {
        ref.read(settingsProvider.notifier).updateSyncReceiveFolder(result);
      }
    } catch (e) {
      // Ignore — picker may fail on some Android devices
    }
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
        if (job.status == 'syncBuildingManifest') {
          return _JobStatusInfo(Icons.inventory_2_outlined, AppColors.neonBlue,
              AppLocalizations.get('syncBuildingManifest', locale));
        }
        if (job.status == 'syncFetchingRemoteManifest') {
          return _JobStatusInfo(Icons.cloud_download_outlined, AppColors.neonBlue,
              AppLocalizations.get('syncFetchingManifest', locale));
        }
        if (job.status == 'syncComputingDiff') {
          return _JobStatusInfo(Icons.compare_arrows, AppColors.neonBlue,
              AppLocalizations.get('syncComputingDiff', locale));
        }
        if (job.status == 'syncWaitingConflictResolution') {
          return _JobStatusInfo(Icons.warning_amber_rounded, Colors.orange,
              AppLocalizations.get('syncWaitingConflicts', locale));
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

  String _formatRelativeTime(DateTime dt, String locale) {
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 1) return AppLocalizations.get('justNow', locale);
    if (diff.inMinutes < 60) return '${diff.inMinutes}m';
    if (diff.inHours < 24) return '${diff.inHours}h';
    return '${diff.inDays}d';
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

class _FileSection {
  final String label;
  final List<SyncFileItem> items;
  final Color color;
  const _FileSection(this.label, this.items, this.color);
}
