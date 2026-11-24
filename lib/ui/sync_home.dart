import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:anyware/features/esitleme/data/esitleme_service.dart';
import 'package:anyware/features/esitleme/presentation/providers.dart';
import 'package:anyware/features/pairing/presentation/providers.dart';
import 'package:anyware/features/server_sync/data/server_sync_service.dart';
import 'package:anyware/features/server_sync/presentation/server_sync_job_wizard.dart';
import 'package:anyware/features/server_sync/presentation/server_sync_screen.dart';
import 'package:anyware/features/settings/presentation/providers.dart';
import 'package:anyware/features/sync/data/sync_service.dart';
import 'package:anyware/features/sync/domain/sync_state.dart';
import 'package:anyware/features/sync/presentation/sync_screen.dart';
import 'package:anyware/ui/devices_home.dart';
import 'package:anyware/ui/ui_kit.dart';
import 'package:anyware/ui/ui_strings.dart';

/// Eşitleme: folders kept the same with paired devices (Syncthing, as LifeOS)
/// and with servers (SFTP, WebDAV, cloud).
class SyncHome extends ConsumerWidget {
  const SyncHome({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ui = Ui.of(context);
    final locale = ref.watch(settingsProvider).locale;
    final folders = ref.watch(syncedFoldersProvider).valueOrNull ?? const <SyncedFolder>[];
    final store = ref.watch(trustStoreProvider);
    final serverJobs = ref.watch(serverSyncServiceProvider).jobs;
    final oldJobs = ref.watch(syncServiceProvider).jobs;

    return Scaffold(
      backgroundColor: ui.bg,
      body: SafeArea(
        bottom: false,
        child: ListView(
          padding: const EdgeInsets.only(bottom: 32),
          children: [
            PageHeader(
              title: S.get('sync', locale),
              actions: [
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: FilledButton.icon(
                    onPressed: () => _newJob(context, ref, locale),
                    style: FilledButton.styleFrom(
                      backgroundColor: ui.accent,
                      foregroundColor: Colors.white,
                      minimumSize: const Size(0, 44),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    icon: const Icon(Icons.add_rounded, size: 18),
                    label: Text(S.get('newSync', locale)),
                  ),
                ),
              ],
            ),
            SectionHeader(S.get('withDevices', locale)),
            if (folders.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Text(S.get('noDeviceSync', locale),
                    style: TextStyle(fontSize: 13, color: ui.muted, height: 1.45)),
              )
            else
              Panel(children: [
                for (final f in folders)
                  SyncedFolderTile(
                    folder: f,
                    locale: locale,
                    deviceName: store.byId(f.device)?.name,
                  ),
              ]),
            SectionHeader(S.get('withServers', locale)),
            if (serverJobs.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Text(S.get('noServerSync', locale), style: TextStyle(fontSize: 13, color: ui.muted)),
              )
            else
              Panel(children: [
                for (final job in serverJobs)
                  ListTile(
                    leading: Icon(Icons.dns_rounded, color: ui.accentText),
                    title: Text(job.name),
                    isThreeLine: job.phase == SyncJobPhase.error,
                    subtitle: Text(
                      job.phase == SyncJobPhase.error && (job.status ?? '').isNotEmpty
                          ? '${job.serverName} · ${job.status}'
                          : '${job.serverName} · ${job.sourceDirectory}',
                      maxLines: job.phase == SyncJobPhase.error ? 3 : 1,
                      overflow: TextOverflow.ellipsis,
                      style: job.phase == SyncJobPhase.error ? TextStyle(color: ui.danger) : null,
                    ),
                    trailing: job.phase == SyncJobPhase.syncing
                        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                        : PopupMenuButton<int>(
                            onSelected: (v) async {
                              final service = ref.read(serverSyncServiceProvider.notifier);
                              if (v == 0) await service.confirmMassDeletion(job.id);
                              if (v == 1) await service.resetHostKey(job.serverId);
                              if (v == 2 && context.mounted) {
                                _open(context, S.get('serverJobs', locale), const ServerSyncScreen());
                              }
                            },
                            itemBuilder: (_) => [
                              if ((job.status ?? '').contains('confirm them'))
                                PopupMenuItem(value: 0, child: Text(S.get('confirmDeletes', locale))),
                              if ((job.status ?? '').toLowerCase().contains('host key'))
                                PopupMenuItem(value: 1, child: Text(S.get('resetHostKey', locale))),
                              PopupMenuItem(value: 2, child: Text(S.get('openServerSync', locale))),
                            ],
                          ),
                    onTap: () => _open(context, S.get('serverJobs', locale), const ServerSyncScreen()),
                  ),
              ]),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: () => _open(context, S.get('serverJobs', locale), const ServerSyncScreen()),
                  child: Text(S.get('openServerSync', locale)),
                ),
              ),
            ),
            if (oldJobs.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: () => _open(
                      context,
                      S.get('oldSyncJobs', locale, {'n': '${oldJobs.length}'}),
                      const SyncScreen(),
                    ),
                    child: Text(S.get('oldSyncJobs', locale, {'n': '${oldJobs.length}'})),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  static void _open(BuildContext context, String title, Widget screen) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => Scaffold(appBar: AppBar(title: Text(title)), body: screen),
    ));
  }

  Future<void> _newJob(BuildContext context, WidgetRef ref, String locale) async {
    final choice = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.devices_rounded),
              title: Text(S.get('newSyncDevice', locale)),
              subtitle: Text(S.get('newSyncDeviceHint', locale)),
              onTap: () => Navigator.of(sheet).pop(0),
            ),
            ListTile(
              leading: const Icon(Icons.dns_rounded),
              title: Text(S.get('newSyncServer', locale)),
              subtitle: Text(S.get('newSyncServerHint', locale)),
              onTap: () => Navigator.of(sheet).pop(1),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (!context.mounted || choice == null) return;
    if (choice == 1) {
      await Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => const ServerSyncJobWizard(),
      ));
      return;
    }
    final rows = ref.read(pairedRowsProvider).where((r) => r.trusted.isPinned).toList();
    final row = await showModalBottomSheet<PairedRow>(
      context: context,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(S.get('chooseDevice', locale),
                  style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
            ),
            if (rows.isEmpty)
              Padding(
                padding: const EdgeInsets.all(20),
                child: Text(S.get('syncNeedsPin', locale)),
              ),
            for (final r in rows)
              ListTile(
                leading: DeviceAvatar(platform: r.trusted.platform, reach: r.reach, size: 40),
                title: Text(r.trusted.name),
                subtitle: Text(S.get(r.live != null ? 'reachLan' : 'reachOff', locale)),
                enabled: r.live != null,
                onTap: () => Navigator.of(sheet).pop(r),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (row != null && context.mounted) await startFolderSync(context, ref, row);
  }
}
