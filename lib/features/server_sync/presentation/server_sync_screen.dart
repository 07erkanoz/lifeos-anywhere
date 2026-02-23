import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:anyware/core/theme.dart';
import 'package:anyware/features/server_sync/data/server_sync_service.dart';
import 'package:anyware/features/server_sync/domain/server_sync_job.dart';
import 'package:anyware/features/server_sync/domain/server_sync_state.dart';
import 'package:anyware/features/server_sync/domain/sftp_server_config.dart';
import 'package:anyware/features/server_sync/presentation/server_config_dialog.dart';
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
      if (syncState.hasServers)
        IconButton(
          icon: const Icon(Icons.add_rounded),
          tooltip: AppLocalizations.get('newServerSyncJob', locale),
          onPressed: () => _openJobWizard(context),
        ),
    ];

    final body = syncState.hasServers
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
          '${syncState.servers.length}',
          locale,
        ),
        const SizedBox(height: 8),

        ...syncState.servers.map((server) =>
            _buildServerCard(server, syncState, locale, isDark)),

        const SizedBox(height: 24),

        // ── Jobs section ──
        if (syncState.hasJobs) ...[
          _buildSectionHeader(
            Icons.sync_rounded,
            AppLocalizations.get('serverSyncJobs', locale),
            '${syncState.jobs.length}',
            locale,
          ),
          const SizedBox(height: 8),

          ...syncState.jobs
              .map((job) => _buildJobCard(job, syncState, locale, isDark)),
        ],

        // Add job CTA if servers exist but no jobs
        if (syncState.hasServers && !syncState.hasJobs) ...[
          const SizedBox(height: 32),
          Center(
            child: FilledButton.icon(
              onPressed: () => _openJobWizard(context),
              icon: const Icon(Icons.add_rounded, size: 18),
              label: Text(
                  AppLocalizations.get('newServerSyncJob', locale)),
            ),
          ),
        ],
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

  // ── Server card ──

  Widget _buildServerCard(SftpServerConfig server,
      ServerSyncState syncState, String locale, bool isDark) {
    final jobCount = syncState.jobsForServer(server.id).length;

    return GestureDetector(
      onSecondaryTapUp: (details) =>
          _showServerContextMenu(context, details.globalPosition, server, locale),
      child: Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: GlassmorphismCard(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 20,
                  backgroundColor:
                      AppColors.neonBlue.withValues(alpha: 0.15),
                  child: const Icon(Icons.dns_rounded,
                      size: 20, color: AppColors.neonBlue),
                ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(server.name,
                        style: const TextStyle(
                            fontWeight: FontWeight.w600, fontSize: 15)),
                    Text('${server.host}:${server.port}',
                        style: TextStyle(
                            fontSize: 12,
                            color:
                                isDark ? Colors.white54 : Colors.black45)),
                    if (server.lastConnectedAt != null)
                      Text(
                        AppLocalizations.get('serverLastConnected', locale).replaceAll('{time}', _formatTime(server.lastConnectedAt!)),
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
                    _showServerDialog(context, server: server),
                tooltip: AppLocalizations.get('editServer', locale),
              ),
              // Delete
              IconButton(
                icon: Icon(Icons.delete_outline_rounded,
                    size: 18, color: Colors.red.shade300),
                onPressed: () => _confirmDeleteServer(server, locale),
                tooltip: AppLocalizations.get('deleteServer', locale),
              ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ── Server context menu ──

  void _showServerContextMenu(
    BuildContext context, Offset position, SftpServerConfig server, String locale,
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
          _showServerDialog(context, server: server);
          break;
        case 'delete':
          _confirmDeleteServer(server, locale);
          break;
      }
    });
  }

  // ── Job card ──

  Widget _buildJobCard(ServerSyncJob job, ServerSyncState syncState,
      String locale, bool isDark) {
    final server = syncState.serverById(job.serverId);

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

    return GestureDetector(
      onSecondaryTapUp: (details) =>
          _showJobContextMenu(context, details.globalPosition, job, locale),
      child: Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: GlassmorphismCard(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Header
                Row(
                  children: [
                    Icon(phaseIcon, size: 18, color: phaseColor),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(job.name,
                          style: const TextStyle(
                              fontWeight: FontWeight.w600, fontSize: 15)),
                    ),
                    if (job.liveWatch)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: Icon(Icons.remove_red_eye_rounded,
                            size: 16, color: AppColors.neonGreen),
                      ),
                    Text(job.directionArrow,
                        style: TextStyle(
                            fontSize: 16, color: phaseColor)),
                  ],
                ),
              const SizedBox(height: 6),

              // Source → Server
              Text(
                '${job.sourceDirectory} ${job.directionArrow} ${server?.name ?? job.serverName}',
                style: TextStyle(
                    fontSize: 12,
                    color: isDark ? Colors.white54 : Colors.black45),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),

              // Progress bar (when syncing)
              if (job.phase == SyncJobPhase.syncing && job.totalBytes > 0) ...[
                const SizedBox(height: 8),
                LinearProgressIndicator(
                  value: job.progress,
                  backgroundColor: Colors.grey.withValues(alpha: 0.2),
                  valueColor:
                      AlwaysStoppedAnimation<Color>(AppColors.neonBlue),
                ),
                const SizedBox(height: 4),
                Text(
                  '${job.syncedCount} / ${job.fileItems.length} files • ${job.progressPercent}',
                  style: TextStyle(
                      fontSize: 11,
                      color: isDark ? Colors.white38 : Colors.black26),
                ),
              ],

              // Status text
              if (job.status != null &&
                  job.phase != SyncJobPhase.idle) ...[
                const SizedBox(height: 4),
                Text(
                  _localizeStatus(job.status!, locale),
                  style: TextStyle(fontSize: 12, color: phaseColor),
                ),
              ],

              // Last sync time
              if (job.lastSyncTime != null) ...[
                const SizedBox(height: 4),
                Text(
                  '${AppLocalizations.get('syncLastSync', locale)}: ${_formatTime(job.lastSyncTime!)}',
                  style: TextStyle(
                      fontSize: 11,
                      color: isDark ? Colors.white30 : Colors.black26),
                ),
              ],

              // Controls
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (job.phase == SyncJobPhase.idle ||
                      job.phase == SyncJobPhase.error)
                    IconButton(
                      icon: const Icon(Icons.play_arrow_rounded, size: 20),
                      onPressed: () => ref
                          .read(serverSyncServiceProvider.notifier)
                          .startJob(job.id),
                      tooltip: AppLocalizations.get('syncNow', locale),
                      color: AppColors.neonGreen,
                    ),
                  if (job.phase == SyncJobPhase.syncing)
                    IconButton(
                      icon: const Icon(Icons.pause_rounded, size: 20),
                      onPressed: () => ref
                          .read(serverSyncServiceProvider.notifier)
                          .pauseJob(job.id),
                      color: Colors.orange,
                    ),
                  if (job.phase == SyncJobPhase.paused)
                    IconButton(
                      icon: const Icon(Icons.play_arrow_rounded, size: 20),
                      onPressed: () => ref
                          .read(serverSyncServiceProvider.notifier)
                          .resumeJob(job.id),
                      color: AppColors.neonGreen,
                    ),
                  if (job.isActive)
                    IconButton(
                      icon: const Icon(Icons.stop_rounded, size: 20),
                      onPressed: () => ref
                          .read(serverSyncServiceProvider.notifier)
                          .stopJob(job.id),
                      color: Colors.red.shade300,
                    ),
                  IconButton(
                    icon: Icon(Icons.delete_outline_rounded,
                        size: 18, color: Colors.red.shade300),
                    onPressed: () =>
                        _confirmDeleteJob(job, locale),
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

  void _showServerDialog(BuildContext context,
      {SftpServerConfig? server}) {
    showDialog(
      context: context,
      builder: (_) => ServerConfigDialog(server: server),
    );
  }

  void _openJobWizard(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(
          builder: (_) => const ServerSyncJobWizard()),
    );
  }

  void _confirmDeleteServer(
      SftpServerConfig server, String locale) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(AppLocalizations.get('deleteServer', locale)),
        content: Text(AppLocalizations.get('deleteServerConfirm', locale)
            .replaceAll('{name}', server.name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(AppLocalizations.get('cancel', locale)),
          ),
          FilledButton(
            onPressed: () {
              ref
                  .read(serverSyncServiceProvider.notifier)
                  .deleteServer(server.id);
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
