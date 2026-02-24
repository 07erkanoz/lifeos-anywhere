import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:anyware/core/theme.dart';
import 'package:anyware/features/server_sync/data/server_sync_service.dart';
import 'package:anyware/features/server_sync/domain/server_sync_job.dart';
import 'package:anyware/features/server_sync/domain/sync_account.dart';
import 'package:anyware/features/settings/presentation/providers.dart';
import 'package:anyware/features/sync/domain/sync_state.dart';
import 'package:anyware/i18n/app_localizations.dart';

/// Detail page for a server sync job — shows configuration, progress,
/// file list, timestamps and errors.
class ServerSyncJobDetail extends ConsumerWidget {
  const ServerSyncJobDetail({super.key, required this.jobId});

  final String jobId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final syncState = ref.watch(serverSyncServiceProvider);
    final settings = ref.watch(settingsProvider);
    final locale = settings.locale;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final job = syncState.jobById(jobId);
    if (job == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: Text('Job not found')),
      );
    }

    final account = syncState.accountById(job.serverId);

    return Scaffold(
      appBar: AppBar(
        title: Text(job.name),
        actions: _buildActions(context, ref, job, locale),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ── Status card ──
          _buildStatusCard(context, job, account, locale, isDark),
          const SizedBox(height: 16),

          // ── Info card ──
          _buildInfoCard(context, job, account, locale, isDark),
          const SizedBox(height: 16),

          // ── Progress (when syncing) ──
          if (job.phase == SyncJobPhase.syncing) ...[
            _buildProgressCard(context, job, locale, isDark),
            const SizedBox(height: 16),
          ],

          // ── File list ──
          if (job.fileItems.isNotEmpty) ...[
            _buildFileListCard(context, job, locale, isDark),
            const SizedBox(height: 16),
          ],

          // ── Errors ──
          if (job.failedFiles.isNotEmpty) ...[
            _buildErrorsCard(context, job, locale, isDark),
            const SizedBox(height: 16),
          ],
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Actions
  // ═══════════════════════════════════════════════════════════════════════════

  List<Widget> _buildActions(
      BuildContext context, WidgetRef ref, ServerSyncJob job, String locale) {
    final notifier = ref.read(serverSyncServiceProvider.notifier);

    return [
      if (job.phase == SyncJobPhase.idle || job.phase == SyncJobPhase.error)
        IconButton(
          icon: const Icon(Icons.play_arrow_rounded),
          tooltip: AppLocalizations.get('syncNow', locale),
          color: AppColors.neonGreen,
          onPressed: () => notifier.startJob(job.id),
        ),
      if (job.phase == SyncJobPhase.syncing)
        IconButton(
          icon: const Icon(Icons.pause_rounded),
          tooltip: AppLocalizations.get('pause', locale),
          color: Colors.orange,
          onPressed: () => notifier.pauseJob(job.id),
        ),
      if (job.phase == SyncJobPhase.paused)
        IconButton(
          icon: const Icon(Icons.play_arrow_rounded),
          tooltip: AppLocalizations.get('resume', locale),
          color: AppColors.neonGreen,
          onPressed: () => notifier.resumeJob(job.id),
        ),
      if (job.isActive)
        IconButton(
          icon: const Icon(Icons.stop_rounded),
          tooltip: AppLocalizations.get('stop', locale),
          color: Colors.red.shade300,
          onPressed: () => notifier.stopJob(job.id),
        ),
    ];
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Status card — big phase indicator
  // ═══════════════════════════════════════════════════════════════════════════

  Widget _buildStatusCard(BuildContext context, ServerSyncJob job,
      SyncAccount? account, String locale, bool isDark) {
    final (phaseIcon, phaseColor, phaseLabel) = _phaseVisuals(job.phase, locale);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            CircleAvatar(
              radius: 24,
              backgroundColor: phaseColor.withValues(alpha: 0.15),
              child: Icon(phaseIcon, color: phaseColor, size: 28),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(phaseLabel,
                      style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                          color: phaseColor)),
                  const SizedBox(height: 4),
                  if (job.status != null)
                    Text(job.status!,
                        style: TextStyle(
                            fontSize: 13,
                            color: isDark ? Colors.white54 : Colors.black45)),
                ],
              ),
            ),
            Text(job.directionArrow,
                style: TextStyle(fontSize: 28, color: phaseColor)),
          ],
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Info card — paths, server, timestamps
  // ═══════════════════════════════════════════════════════════════════════════

  Widget _buildInfoCard(BuildContext context, ServerSyncJob job,
      SyncAccount? account, String locale, bool isDark) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(AppLocalizations.get('syncJobDetails', locale),
                style:
                    const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
            const SizedBox(height: 12),

            // Source folder
            _infoRow(Icons.folder_rounded, AppLocalizations.get('serverSyncSourceFolder', locale),
                job.sourceDirectory, isDark),
            const SizedBox(height: 10),

            // Target server
            _infoRow(
              _providerIcon(job.providerType),
              AppLocalizations.get('serverSyncTargetServer', locale),
              account?.name ?? job.serverName,
              isDark,
            ),
            const SizedBox(height: 10),

            // Remote path
            if (job.remoteSubPath.isNotEmpty) ...[
              _infoRow(Icons.cloud_rounded,
                  AppLocalizations.get('serverSyncRemoteSubfolder', locale),
                  job.remoteSubPath, isDark),
              const SizedBox(height: 10),
            ],

            const Divider(height: 24),

            // Direction
            _infoRow(
              job.isBidirectional
                  ? Icons.sync_rounded
                  : Icons.arrow_upward_rounded,
              AppLocalizations.get('syncDirection', locale),
              job.isBidirectional
                  ? AppLocalizations.get('syncBidirectional', locale)
                  : AppLocalizations.get('syncOneWay', locale),
              isDark,
            ),
            const SizedBox(height: 10),

            // Live watch
            _infoRow(
              Icons.remove_red_eye_rounded,
              AppLocalizations.get('serverSyncLiveWatch', locale),
              job.liveWatch
                  ? AppLocalizations.get('on', locale)
                  : AppLocalizations.get('off', locale),
              isDark,
            ),

            const Divider(height: 24),

            // Timestamps
            _infoRow(Icons.calendar_today_rounded,
                AppLocalizations.get('syncJobCreated', locale),
                _formatDateTime(job.createdAt), isDark),
            const SizedBox(height: 10),

            _infoRow(
              Icons.update_rounded,
              AppLocalizations.get('syncLastSync', locale),
              job.lastSyncTime != null
                  ? _formatDateTime(job.lastSyncTime!)
                  : '—',
              isDark,
            ),

            if (job.syncStartTime != null) ...[
              const SizedBox(height: 10),
              _infoRow(Icons.timer_rounded,
                  AppLocalizations.get('syncStartedAt', locale),
                  _formatDateTime(job.syncStartTime!), isDark),
            ],
          ],
        ),
      ),
    );
  }

  Widget _infoRow(IconData icon, String label, String value, bool isDark) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 16, color: isDark ? Colors.white38 : Colors.black26),
        const SizedBox(width: 8),
        SizedBox(
          width: 120,
          child: Text(label,
              style: TextStyle(
                  fontSize: 12,
                  color: isDark ? Colors.white38 : Colors.black26)),
        ),
        Expanded(
          child: Text(value,
              style: const TextStyle(fontSize: 13),
              overflow: TextOverflow.ellipsis,
              maxLines: 2),
        ),
      ],
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Progress card
  // ═══════════════════════════════════════════════════════════════════════════

  Widget _buildProgressCard(
      BuildContext context, ServerSyncJob job, String locale, bool isDark) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const SizedBox(
                  width: 16, height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 10),
                Text(AppLocalizations.get('syncProgress', locale),
                    style: const TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 15)),
              ],
            ),
            const SizedBox(height: 12),
            LinearProgressIndicator(
              value: job.progress,
              backgroundColor: Colors.grey.withValues(alpha: 0.2),
              valueColor: const AlwaysStoppedAnimation(AppColors.neonBlue),
              minHeight: 6,
              borderRadius: BorderRadius.circular(3),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '${job.syncedCount} / ${job.fileItems.length} ${AppLocalizations.get('files', locale)}',
                  style: TextStyle(
                      fontSize: 12,
                      color: isDark ? Colors.white54 : Colors.black45),
                ),
                Text(job.progressPercent,
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: AppColors.neonBlue)),
              ],
            ),
            if (job.failedCount > 0) ...[
              const SizedBox(height: 4),
              Text(
                '${job.failedCount} ${AppLocalizations.get('filesFailed', locale)}',
                style: TextStyle(fontSize: 12, color: Colors.red.shade400),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // File list card
  // ═══════════════════════════════════════════════════════════════════════════

  Widget _buildFileListCard(
      BuildContext context, ServerSyncJob job, String locale, bool isDark) {
    final items = job.fileItems;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.description_rounded, size: 18),
                const SizedBox(width: 8),
                Text(
                  '${AppLocalizations.get('syncedFiles', locale)} (${items.length})',
                  style: const TextStyle(
                      fontWeight: FontWeight.w600, fontSize: 15),
                ),
              ],
            ),
            const SizedBox(height: 12),
            ...items.take(100).map((item) => _buildFileRow(item, isDark)),
            if (items.length > 100)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '+${items.length - 100} more…',
                  style: TextStyle(
                      fontSize: 12,
                      color: isDark ? Colors.white38 : Colors.black26),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildFileRow(SyncFileItem item, bool isDark) {
    final (icon, color) = _fileStatusVisuals(item.status);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              item.relativePath,
              style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (item.fileSize > 0) ...[
            const SizedBox(width: 8),
            Text(_formatBytes(item.fileSize),
                style: TextStyle(
                    fontSize: 11,
                    color: isDark ? Colors.white30 : Colors.black26)),
          ],
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Errors card
  // ═══════════════════════════════════════════════════════════════════════════

  Widget _buildErrorsCard(
      BuildContext context, ServerSyncJob job, String locale, bool isDark) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.error_outline_rounded,
                    size: 18, color: Colors.red.shade400),
                const SizedBox(width: 8),
                Text(
                  '${AppLocalizations.get('syncErrors', locale)} (${job.failedFiles.length})',
                  style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 15,
                      color: Colors.red.shade400),
                ),
              ],
            ),
            const SizedBox(height: 12),
            ...job.failedFiles.take(20).map((err) => Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(err.filePath,
                          style: const TextStyle(
                              fontSize: 12, fontFamily: 'monospace')),
                      Text(err.error,
                          style: TextStyle(
                              fontSize: 11, color: Colors.red.shade300)),
                    ],
                  ),
                )),
          ],
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Helpers
  // ═══════════════════════════════════════════════════════════════════════════

  (IconData, Color, String) _phaseVisuals(SyncJobPhase phase, String locale) {
    switch (phase) {
      case SyncJobPhase.idle:
        return (Icons.pause_circle_rounded, Colors.grey,
            AppLocalizations.get('syncPhaseIdle', locale));
      case SyncJobPhase.syncing:
        return (Icons.sync_rounded, AppColors.neonBlue,
            AppLocalizations.get('syncPhaseSyncing', locale));
      case SyncJobPhase.watching:
        return (Icons.visibility_rounded, AppColors.neonGreen,
            AppLocalizations.get('syncPhaseWatching', locale));
      case SyncJobPhase.error:
        return (Icons.error_rounded, Colors.red,
            AppLocalizations.get('syncPhaseError', locale));
      case SyncJobPhase.paused:
        return (Icons.pause_rounded, Colors.orange,
            AppLocalizations.get('syncPhasePaused', locale));
    }
  }

  IconData _providerIcon(SyncProviderType type) {
    switch (type) {
      case SyncProviderType.sftp:
        return Icons.dns_rounded;
      case SyncProviderType.gdrive:
        return Icons.cloud_rounded;
      case SyncProviderType.onedrive:
        return Icons.cloud_queue_rounded;
    }
  }

  (IconData, Color) _fileStatusVisuals(SyncFileStatus status) {
    switch (status) {
      case SyncFileStatus.completed:
        return (Icons.check_circle_rounded, AppColors.neonGreen);
      case SyncFileStatus.failed:
        return (Icons.error_rounded, Colors.red);
      case SyncFileStatus.syncing:
        return (Icons.sync_rounded, AppColors.neonBlue);
      case SyncFileStatus.pending:
        return (Icons.schedule_rounded, Colors.grey);
      case SyncFileStatus.paused:
        return (Icons.pause_circle_rounded, Colors.orange);
      case SyncFileStatus.skipped:
        return (Icons.skip_next_rounded, Colors.grey);
    }
  }

  String _formatDateTime(DateTime dt) {
    final local = dt.toLocal();
    final d = '${local.day.toString().padLeft(2, '0')}/'
        '${local.month.toString().padLeft(2, '0')}/'
        '${local.year}';
    final t = '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
    return '$d $t';
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}
