import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:anyware/core/theme.dart';
import 'package:anyware/features/server_sync/data/server_sync_service.dart';
import 'package:anyware/features/server_sync/domain/server_sync_job.dart';
import 'package:anyware/features/server_sync/domain/server_sync_state.dart';
import 'package:anyware/features/server_sync/domain/sync_account.dart';
import 'package:anyware/features/server_sync/presentation/server_config_dialog.dart';
import 'package:anyware/features/server_sync/presentation/server_sync_job_detail.dart';
import 'package:anyware/features/server_sync/presentation/server_sync_job_wizard.dart';
import 'package:anyware/features/settings/presentation/providers.dart';
import 'package:anyware/features/sync/domain/sync_state.dart';
import 'package:anyware/i18n/app_localizations.dart';
import 'package:anyware/widgets/desktop_content_shell.dart';
import 'package:anyware/widgets/glassmorphism.dart';

class ServerSyncScreen extends ConsumerStatefulWidget {
  const ServerSyncScreen({super.key});

  @override
  ConsumerState<ServerSyncScreen> createState() => _ServerSyncScreenState();
}

class _ServerSyncScreenState extends ConsumerState<ServerSyncScreen> {
  @override
  Widget build(BuildContext context) {
    final syncState = ref.watch(serverSyncServiceProvider);
    final settings = ref.watch(settingsProvider);
    final locale = settings.locale;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final actions = <Widget>[
      IconButton(
        icon: const Icon(Icons.dns_rounded),
        tooltip: AppLocalizations.get('addServer', locale),
        onPressed: () => _showServerDialog(context),
      ),
      if (syncState.hasAccounts)
        IconButton(
          icon: const Icon(Icons.add_rounded),
          tooltip: AppLocalizations.get('newServerSyncJob', locale),
          onPressed: () => _openJobWizard(context),
        ),
    ];

    final body = syncState.hasAccounts
        ? _buildContent(syncState, locale, isDark)
        : _buildEmptyState(locale, isDark);

    if (DesktopShellScope.of(context)) {
      return DesktopContentShell(
        title: AppLocalizations.get('serverSync', locale),
        actions: actions,
        child: body,
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(AppLocalizations.get('serverSync', locale)),
        actions: actions,
      ),
      body: body,
    );
  }

  // ── Empty state ──

  Widget _buildEmptyState(String locale, bool isDark) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.cloud_off_rounded,
              size: 64,
              color: isDark ? Colors.white24 : Colors.black12),
          const SizedBox(height: 16),
          Text(
            AppLocalizations.get('noServers', locale),
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: isDark ? Colors.white54 : Colors.black45,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            AppLocalizations.get('noServersDesc', locale),
            style: TextStyle(
                fontSize: 14,
                color: isDark ? Colors.white30 : Colors.black26),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: () => _showServerDialog(context),
            icon: const Icon(Icons.add_rounded, size: 18),
            label: Text(AppLocalizations.get('addServer', locale)),
          ),
        ],
      ),
    );
  }

  // ── Main content ──

  Widget _buildContent(
      ServerSyncState syncState, String locale, bool isDark) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // ── Servers section ──
        _buildSectionHeader(
          Icons.dns_rounded,
          AppLocalizations.get('serverSync', locale),
          '${syncState.accounts.length}',
          locale,
        ),
        const SizedBox(height: 8),

        ...syncState.accounts.map((account) =>
            _buildAccountCard(account, syncState, locale, isDark)),

        const SizedBox(height: 24),

        // ── Jobs section ──
        _buildSectionHeader(
          Icons.sync_rounded,
          AppLocalizations.get('serverSyncJobs', locale),
          '${syncState.jobs.length}',
          locale,
        ),
        const SizedBox(height: 8),

        if (syncState.hasJobs)
          ...syncState.jobs
              .map((job) => _buildJobCard(job, syncState, locale, isDark))
        else
          _buildEmptyJobsState(locale, isDark),
      ],
    );
  }

  Widget _buildSectionHeader(
      IconData icon, String title, String count, String locale) {
    return Row(
      children: [
        Icon(icon, size: 20, color: AppColors.neonBlue),
        const SizedBox(width: 8),
        Text(title,
            style: const TextStyle(
                fontSize: 16, fontWeight: FontWeight.w600)),
        const SizedBox(width: 8),
        Container(
          padding:
              const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
            color: AppColors.neonBlue.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(count,
              style: const TextStyle(
                  fontSize: 12, color: AppColors.neonBlue)),
        ),
      ],
    );
  }

  // ── Account card ──

  /// Returns the icon and color for a given provider type.
  (IconData, Color) _providerVisuals(SyncProviderType type) {
    switch (type) {
      case SyncProviderType.sftp:
        return (Icons.dns_rounded, AppColors.neonBlue);
      case SyncProviderType.gdrive:
        return (Icons.cloud_rounded, const Color(0xFF34A853));
      case SyncProviderType.onedrive:
        return (Icons.cloud_queue_rounded, const Color(0xFF0078D4));
    }
  }

  Widget _buildAccountCard(SyncAccount account,
      ServerSyncState syncState, String locale, bool isDark) {
    final jobCount = syncState.jobsForAccount(account.id).length;
    final (icon, color) = _providerVisuals(account.providerType);

    return GestureDetector(
      onSecondaryTapUp: (details) =>
          _showAccountContextMenu(context, details.globalPosition, account, locale),
      child: Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: GlassmorphismCard(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 20,
                  backgroundColor: color.withValues(alpha: 0.15),
                  child: Icon(icon, size: 20, color: color),
                ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(account.name,
                              style: const TextStyle(
                                  fontWeight: FontWeight.w600, fontSize: 15),
                              overflow: TextOverflow.ellipsis),
                        ),
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 1),
                          decoration: BoxDecoration(
                            color: color.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(account.providerType.shortLabel,
                              style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w600,
                                  color: color)),
                        ),
                      ],
                    ),
                    Text(account.subtitle,
                        style: TextStyle(
                            fontSize: 12,
                            color:
                                isDark ? Colors.white54 : Colors.black45)),
                    if (account.lastConnectedAt != null)
                      Text(
                        AppLocalizations.get('serverLastConnected', locale).replaceAll('{time}', _formatTime(account.lastConnectedAt!)),
                        style: TextStyle(
                            fontSize: 11,
                            color: isDark
                                ? Colors.white30
                                : Colors.black26),
                      ),
                  ],
                ),
              ),
              // Job count badge
              if (jobCount > 0)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.grey.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text('$jobCount job',
                      style: const TextStyle(fontSize: 11)),
                ),
              // Edit
              IconButton(
                icon: const Icon(Icons.edit_rounded, size: 18),
                onPressed: () =>
                    _showAccountDialog(context, account: account),
                tooltip: AppLocalizations.get('editServer', locale),
              ),
              // Delete
              IconButton(
                icon: Icon(Icons.delete_outline_rounded,
                    size: 18, color: Colors.red.shade300),
                onPressed: () => _confirmDeleteAccount(account, locale),
                tooltip: AppLocalizations.get('deleteServer', locale),
              ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ── Account context menu ──

  void _showAccountContextMenu(
    BuildContext context, Offset position, SyncAccount account, String locale,
  ) {
    showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx, position.dy, position.dx, position.dy,
      ),
      items: [
        PopupMenuItem(
          value: 'edit',
          child: Row(children: [
            const Icon(Icons.edit_rounded, size: 18),
            const SizedBox(width: 10),
            Text(AppLocalizations.get('editServer', locale)),
          ]),
        ),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: 'delete',
          child: Row(children: [
            Icon(Icons.delete_outline_rounded, size: 18, color: Colors.red.shade400),
            const SizedBox(width: 10),
            Text(
              AppLocalizations.get('deleteServer', locale),
              style: TextStyle(color: Colors.red.shade400),
            ),
          ]),
        ),
      ],
    ).then((value) {
      if (value == null) return;
      switch (value) {
        case 'edit':
          _showAccountDialog(context, account: account);
          break;
        case 'delete':
          _confirmDeleteAccount(account, locale);
          break;
      }
    });
  }

  // ── Empty jobs state ──

  Widget _buildEmptyJobsState(String locale, bool isDark) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 32),
      child: Center(
        child: Column(
          children: [
            Icon(Icons.sync_disabled_rounded,
                size: 48, color: isDark ? Colors.white24 : Colors.black12),
            const SizedBox(height: 12),
            Text(
              AppLocalizations.get('syncNoJobs', locale),
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: isDark ? Colors.white54 : Colors.black45,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              AppLocalizations.get('syncNoJobsDesc', locale),
              style: TextStyle(
                  fontSize: 13,
                  color: isDark ? Colors.white30 : Colors.black26),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () => _openJobWizard(context),
              icon: const Icon(Icons.add_rounded, size: 18),
              label: Text(AppLocalizations.get('newServerSyncJob', locale)),
            ),
          ],
        ),
      ),
    );
  }

  // ── Job card ──

  Widget _buildJobCard(ServerSyncJob job, ServerSyncState syncState,
      String locale, bool isDark) {
    final account = syncState.accountById(job.serverId);
    final providerType = account?.providerType ?? job.providerType;
    final (provIcon, provColor) = _providerVisuals(providerType);

    // Phase visuals
    Color phaseColor;
    IconData phaseIcon;
    switch (job.phase) {
      case SyncJobPhase.idle:
        phaseColor = Colors.grey;
        phaseIcon = Icons.pause_circle_rounded;
        break;
      case SyncJobPhase.syncing:
        phaseColor = AppColors.neonBlue;
        phaseIcon = Icons.sync_rounded;
        break;
      case SyncJobPhase.watching:
        phaseColor = AppColors.neonGreen;
        phaseIcon = Icons.visibility_rounded;
        break;
      case SyncJobPhase.error:
        phaseColor = Colors.red;
        phaseIcon = Icons.error_rounded;
        break;
      case SyncJobPhase.paused:
        phaseColor = Colors.orange;
        phaseIcon = Icons.pause_rounded;
        break;
    }

    // Last sync status line
    Widget statusLine;
    if (job.phase == SyncJobPhase.syncing) {
      statusLine = Row(
        children: [
          SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              valueColor: AlwaysStoppedAnimation<Color>(AppColors.neonBlue),
            ),
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              job.status != null
                  ? _localizeStatus(job.status!, locale)
                  : '${job.syncedCount} / ${job.fileItems.length} • ${job.progressPercent}',
              style: TextStyle(fontSize: 11, color: AppColors.neonBlue),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      );
    } else if (job.phase == SyncJobPhase.error) {
      statusLine = Row(
        children: [
          Icon(Icons.error_rounded, size: 14, color: Colors.red.shade300),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              '${AppLocalizations.get('syncFailed', locale)}'
              '${job.failedCount > 0 ? ' · ${job.failedCount} ${AppLocalizations.get('filesFailed', locale)}' : ''}',
              style: TextStyle(fontSize: 11, color: Colors.red.shade300),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      );
    } else if (job.lastSyncTime != null) {
      final totalFiles = job.syncedCount + job.failedCount;
      statusLine = Row(
        children: [
          Icon(Icons.check_circle_rounded,
              size: 14, color: AppColors.neonGreen),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              AppLocalizations.get('syncLastSync', locale)
                      .replaceAll('{time}', _formatTime(job.lastSyncTime!)) +
                  (totalFiles > 0
                      ? ' · ${AppLocalizations.get('filesCount', locale).replaceAll('{count}', '$totalFiles')}'
                      : ''),
              style: TextStyle(
                  fontSize: 11,
                  color: isDark ? Colors.white54 : Colors.black45),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      );
    } else {
      statusLine = Row(
        children: [
          Icon(Icons.schedule_rounded,
              size: 14, color: isDark ? Colors.white30 : Colors.black26),
          const SizedBox(width: 6),
          Text(
            AppLocalizations.get('neverSynced', locale),
            style: TextStyle(
                fontSize: 11,
                color: isDark ? Colors.white30 : Colors.black26),
          ),
        ],
      );
    }

    return GestureDetector(
      onTap: () => _openJobDetail(context, job),
      onSecondaryTapUp: (details) =>
          _showJobContextMenu(context, details.globalPosition, job, locale),
      child: Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: GlassmorphismCard(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ── Provider icon ──
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: provColor.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(provIcon, size: 22, color: provColor),
                ),
                const SizedBox(width: 12),

                // ── Info column ──
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Row 1: Name + direction + phase badge
                      Row(
                        children: [
                          Expanded(
                            child: Text(job.name,
                                style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                    fontSize: 14),
                                overflow: TextOverflow.ellipsis,
                                maxLines: 1),
                          ),
                          const SizedBox(width: 6),
                          Text(job.directionArrow,
                              style: TextStyle(
                                  fontSize: 14, color: phaseColor)),
                          const SizedBox(width: 6),
                          Icon(phaseIcon, size: 16, color: phaseColor),
                          if (job.liveWatch) ...[
                            const SizedBox(width: 4),
                            Icon(Icons.remove_red_eye_rounded,
                                size: 14, color: AppColors.neonGreen),
                          ],
                        ],
                      ),
                      const SizedBox(height: 3),

                      // Row 2: source path → account name
                      Text(
                        '${_shortenPath(job.sourceDirectory)} ${job.directionArrow} ${account?.name ?? job.serverName}',
                        style: TextStyle(
                            fontSize: 11,
                            color:
                                isDark ? Colors.white38 : Colors.black38),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),

                      // Progress bar (syncing)
                      if (job.phase == SyncJobPhase.syncing &&
                          job.totalBytes > 0) ...[
                        const SizedBox(height: 6),
                        NeonProgressBar(
                          progress: job.progress,
                          color: AppColors.neonBlue,
                          height: 4,
                        ),
                      ],

                      const SizedBox(height: 4),

                      // Row 3: Status line
                      statusLine,
                    ],
                  ),
                ),

                // ── Quick actions ──
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (job.phase == SyncJobPhase.idle ||
                        job.phase == SyncJobPhase.error)
                      _miniAction(
                        Icons.play_arrow_rounded,
                        AppColors.neonGreen,
                        () => ref
                            .read(serverSyncServiceProvider.notifier)
                            .startJob(job.id),
                      ),
                    if (job.phase == SyncJobPhase.syncing)
                      _miniAction(
                        Icons.pause_rounded,
                        Colors.orange,
                        () => ref
                            .read(serverSyncServiceProvider.notifier)
                            .pauseJob(job.id),
                      ),
                    if (job.phase == SyncJobPhase.paused)
                      _miniAction(
                        Icons.play_arrow_rounded,
                        AppColors.neonGreen,
                        () => ref
                            .read(serverSyncServiceProvider.notifier)
                            .resumeJob(job.id),
                      ),
                    if (job.isActive)
                      _miniAction(
                        Icons.stop_rounded,
                        Colors.red.shade300,
                        () => ref
                            .read(serverSyncServiceProvider.notifier)
                            .stopJob(job.id),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Compact icon button for job card actions.
  Widget _miniAction(IconData icon, Color color, VoidCallback onTap) {
    return SizedBox(
      width: 32,
      height: 32,
      child: IconButton(
        icon: Icon(icon, size: 18),
        color: color,
        padding: EdgeInsets.zero,
        onPressed: onTap,
      ),
    );
  }

  /// Shortens a path for display — keeps last 2 segments.
  String _shortenPath(String path) {
    final sep = path.contains('\\') ? '\\' : '/';
    final parts = path.split(sep).where((p) => p.isNotEmpty).toList();
    if (parts.length <= 2) return path;
    return '...$sep${parts.sublist(parts.length - 2).join(sep)}';
  }

  // ── Job context menu ──

  void _showJobContextMenu(
    BuildContext context, Offset position, ServerSyncJob job, String locale,
  ) {
    final notifier = ref.read(serverSyncServiceProvider.notifier);
    final items = <PopupMenuEntry<String>>[];

    if (job.phase == SyncJobPhase.idle || job.phase == SyncJobPhase.error) {
      items.add(PopupMenuItem(
        value: 'start',
        child: Row(children: [
          Icon(Icons.play_arrow_rounded, size: 18, color: AppColors.neonGreen),
          const SizedBox(width: 10),
          Text(AppLocalizations.get('syncNow', locale)),
        ]),
      ));
    }
    if (job.phase == SyncJobPhase.syncing) {
      items.add(PopupMenuItem(
        value: 'pause',
        child: Row(children: [
          const Icon(Icons.pause_rounded, size: 18, color: Colors.orange),
          const SizedBox(width: 10),
          Text(AppLocalizations.get('pause', locale)),
        ]),
      ));
    }
    if (job.phase == SyncJobPhase.paused) {
      items.add(PopupMenuItem(
        value: 'resume',
        child: Row(children: [
          Icon(Icons.play_arrow_rounded, size: 18, color: AppColors.neonGreen),
          const SizedBox(width: 10),
          Text(AppLocalizations.get('resume', locale)),
        ]),
      ));
    }
    if (job.isActive) {
      items.add(PopupMenuItem(
        value: 'stop',
        child: Row(children: [
          Icon(Icons.stop_rounded, size: 18, color: Colors.red.shade300),
          const SizedBox(width: 10),
          Text(AppLocalizations.get('stop', locale)),
        ]),
      ));
    }

    items.add(const PopupMenuDivider());
    items.add(PopupMenuItem(
      value: 'delete',
      child: Row(children: [
        Icon(Icons.delete_outline_rounded, size: 18, color: Colors.red.shade400),
        const SizedBox(width: 10),
        Text(
          AppLocalizations.get('deleteSync', locale),
          style: TextStyle(color: Colors.red.shade400),
        ),
      ]),
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
          notifier.startJob(job.id);
          break;
        case 'pause':
          notifier.pauseJob(job.id);
          break;
        case 'resume':
          notifier.resumeJob(job.id);
          break;
        case 'stop':
          notifier.stopJob(job.id);
          break;
        case 'delete':
          _confirmDeleteJob(job, locale);
          break;
      }
    });
  }

  // ── Helpers ──

  String _localizeStatus(String status, String locale) {
    // Try to use localization key, fallback to raw status.
    final localized = AppLocalizations.get(status, locale);
    return localized != status ? localized : status;
  }

  String _formatTime(DateTime dt) {
    final local = dt.toLocal();
    final now = DateTime.now();
    final diff = now.difference(local);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inHours < 1) return '${diff.inMinutes}m ago';
    if (diff.inDays < 1) return '${diff.inHours}h ago';
    return '${local.day}/${local.month}/${local.year}';
  }

  Future<void> _showAccountDialog(BuildContext context,
      {SyncAccount? account}) async {
    final isNew = account == null;
    final result = await showDialog<Object>(
      context: context,
      builder: (_) => ServerConfigDialog(account: account),
    );

    // If a NEW account was just created, auto-open the sync job wizard
    // with that account pre-selected so the user can configure a job
    // in one continuous flow.
    if (isNew && result is SyncAccount && mounted) {
      _openJobWizard(context, preselectedAccount: result);
    }
  }

  /// @deprecated Use [_showAccountDialog].
  void _showServerDialog(BuildContext context,
      {SyncAccount? server}) {
    _showAccountDialog(context, account: server);
  }

  void _openJobDetail(BuildContext context, ServerSyncJob job) {
    Navigator.of(context).push(
      MaterialPageRoute(
          builder: (_) => ServerSyncJobDetail(jobId: job.id)),
    );
  }

  void _openJobWizard(BuildContext context, {SyncAccount? preselectedAccount}) {
    Navigator.of(context).push(
      MaterialPageRoute(
          builder: (_) => ServerSyncJobWizard(
                preselectedAccount: preselectedAccount,
              )),
    );
  }

  void _confirmDeleteAccount(
      SyncAccount account, String locale) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(AppLocalizations.get('deleteServer', locale)),
        content: Text(AppLocalizations.get('deleteServerConfirm', locale)
            .replaceAll('{name}', account.name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(AppLocalizations.get('cancel', locale)),
          ),
          FilledButton(
            onPressed: () {
              ref
                  .read(serverSyncServiceProvider.notifier)
                  .deleteAccount(account.id);
              Navigator.of(ctx).pop();
            },
            style: FilledButton.styleFrom(
                backgroundColor: Colors.red),
            child: Text(AppLocalizations.get('deleteServer', locale)),
          ),
        ],
      ),
    );
  }

  void _confirmDeleteJob(ServerSyncJob job, String locale) {
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
              ref
                  .read(serverSyncServiceProvider.notifier)
                  .deleteJob(job.id);
              Navigator.of(ctx).pop();
            },
            style: FilledButton.styleFrom(
                backgroundColor: Colors.red),
            child: Text(AppLocalizations.get('deleteSync', locale)),
          ),
        ],
      ),
    );
  }
}
