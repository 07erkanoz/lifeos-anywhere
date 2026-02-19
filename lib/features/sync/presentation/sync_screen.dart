import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:anyware/core/theme.dart';
import 'package:anyware/features/discovery/domain/device.dart';
import 'package:anyware/features/discovery/presentation/providers.dart';
import 'package:anyware/features/sync/data/sync_service.dart';
import 'package:anyware/features/settings/presentation/providers.dart';
import 'package:anyware/widgets/glassmorphism.dart';
import 'package:anyware/i18n/app_localizations.dart';

class SyncScreen extends ConsumerStatefulWidget {
  const SyncScreen({super.key});

  @override
  ConsumerState<SyncScreen> createState() => _SyncScreenState();
}

class _SyncScreenState extends ConsumerState<SyncScreen> {
  @override
  Widget build(BuildContext context) {
    final syncState = ref.watch(syncServiceProvider);
    final devices = ref.watch(devicesProvider).valueOrNull ?? [];
    final settings = ref.watch(settingsProvider);
    final locale = settings.locale;

    // Filter only Windows devices (sync to PC)
    final windowsDevices = devices.where((d) => d.platform == 'windows').toList();

    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              AppLocalizations.get('folderSyncBeta', locale),
              style: TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.bold,
                color: isDark ? Colors.white : Colors.black87,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              AppLocalizations.get('folderSyncDesc', locale),
              style: TextStyle(
                fontSize: 16,
                color: isDark ? Colors.white70 : Colors.black54,
              ),
            ),
            const SizedBox(height: 32),

            // Source Folder Selection
            _buildSectionHeader(AppLocalizations.get('sourceFolder', locale), isDark),
            const SizedBox(height: 12),
            GlassmorphismCard(
              backgroundColor: (isDark ? Colors.white : Colors.black).withValues(alpha: 0.1),
              padding: EdgeInsets.zero,
              child: ListTile(
                leading: Icon(Icons.folder_open, color: AppColors.neonBlue),
                title: Text(
                  syncState.sourceDirectory ?? AppLocalizations.get('selectFolderToSync', locale),
                  style: TextStyle(
                    color: isDark ? Colors.white : Colors.black87,
                  ),
                ),
                trailing: ElevatedButton(
                  onPressed: syncState.isSyncing
                      ? null
                      : () async {
                          await FilePicker.platform.getDirectoryPath();
                        },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.neonBlue,
                    foregroundColor: Colors.white,
                  ),
                  child: Text(AppLocalizations.get('browse', locale)),
                ),
              ),
            ),

            const SizedBox(height: 24),

            // Target Device Selection
            _buildSectionHeader(AppLocalizations.get('targetDevice', locale), isDark),
            const SizedBox(height: 12),
            if (windowsDevices.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 20),
                child: Text(
                  AppLocalizations.get('noWindowsDevices', locale),
                  style: const TextStyle(color: Colors.grey),
                ),
              )
            else
              DropdownButtonFormField<Device>(
                initialValue: syncState.targetDevice,
                dropdownColor: isDark ? AppColors.darkBg : Colors.white,
                items: windowsDevices.map((d) {
                  return DropdownMenuItem(
                    value: d,
                    child: Text(
                      '${d.name} (${d.ip})',
                      style: TextStyle(color: isDark ? Colors.white : Colors.black),
                    ),
                  );
                }).toList(),
                onChanged: syncState.isSyncing ? null : (d) {
                  // Select device logic
                },
                decoration: InputDecoration(
                  filled: true,
                  fillColor: isDark ? Colors.white.withValues(alpha: 0.05) : Colors.grey[100],
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),

            const SizedBox(height: 32),

            // Actions & Status
            Center(
              child: Column(
                children: [
                  if (syncState.isSyncing) ...[
                    const CircularProgressIndicator(),
                    const SizedBox(height: 16),
                    Text(
                      syncState.status ?? AppLocalizations.get('syncing', locale),
                      style: TextStyle(
                        color: AppColors.neonGreen,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 24),
                    ElevatedButton.icon(
                      onPressed: () {
                        ref.read(syncServiceProvider.notifier).stopSync();
                      },
                      icon: const Icon(Icons.stop),
                      label: Text(AppLocalizations.get('stopSync', locale)),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.red.shade400,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                      ),
                    ),
                  ] else ...[
                    ElevatedButton.icon(
                      onPressed: () async {
                        // 1. Pick Folder
                        final path = await FilePicker.platform.getDirectoryPath();
                        if (path == null) return;

                        if (!context.mounted) return;
                        // 2. Pick Device
                        if (windowsDevices.isEmpty) {
                           ScaffoldMessenger.of(context).showSnackBar(
                             SnackBar(content: Text(AppLocalizations.get('noTargetDevice', locale))),
                           );
                           return;
                        }
                        final target = windowsDevices.first;

                        // 3. Start
                        ref.read(syncServiceProvider.notifier).startSync(path, target);
                      },
                      icon: const Icon(Icons.sync),
                      label: Text(AppLocalizations.get('startSync', locale)),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.neonBlue,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionHeader(String title, bool isDark) {
    return Text(
      title.toUpperCase(),
      style: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.bold,
        letterSpacing: 1.2,
        color: isDark ? Colors.white54 : Colors.grey[700],
      ),
    );
  }
}
