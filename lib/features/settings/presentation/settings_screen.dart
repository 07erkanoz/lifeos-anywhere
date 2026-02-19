import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';
import 'package:permission_handler/permission_handler.dart';

import 'package:anyware/core/constants.dart';
import 'package:anyware/core/tv_detector.dart';
import 'package:anyware/features/settings/presentation/providers.dart';
import 'package:anyware/features/settings/presentation/help_screen.dart';
import 'package:anyware/features/settings/presentation/about_screen.dart';
import 'package:anyware/i18n/app_localizations.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final notifier = ref.read(settingsProvider.notifier);
    final locale = settings.locale;
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(AppLocalizations.get('settings', locale)),
      ),
      body: FocusTraversalGroup(
        policy: OrderedTraversalPolicy(),
        child: ListView(
        padding: const EdgeInsets.only(top: 8, bottom: 32),
        children: [
          // =================================================================
          // General section
          // =================================================================
          _SectionHeader(
            label: AppLocalizations.get('general', locale),
          ),

          // Device name
          ListTile(
            leading: const Icon(Icons.badge_outlined),
            title: Text(AppLocalizations.get('deviceName', locale)),
            subtitle: Text(
              settings.deviceName.isNotEmpty
                  ? settings.deviceName
                  : '---',
            ),
            trailing: const Icon(Icons.edit, size: 20),
            onTap: () => _showDeviceNameDialog(
              context,
              settings.deviceName,
              notifier,
              locale,
            ),
          ),

          // Download path
          ListTile(
            leading: const Icon(Icons.folder_outlined),
            title: Text(AppLocalizations.get('saveLocation', locale)),
            subtitle: Text(
              settings.downloadPath.isNotEmpty
                  ? settings.downloadPath
                  : '---',
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
            ),
            trailing: OutlinedButton(
              onPressed: () => _pickDownloadPath(context, notifier, locale),
              child: Text(AppLocalizations.get('chooseFolder', locale)),
            ),
          ),

          const Divider(indent: 16, endIndent: 16, height: 24),

          // =================================================================
          // Transfer section
          // =================================================================
          _SectionHeader(
            label: AppLocalizations.get('transfer', locale),
          ),

          // Auto-accept
          SwitchListTile(
            secondary: const Icon(Icons.file_download_outlined),
            title: Text(AppLocalizations.get('autoAccept', locale)),
            subtitle: Text(
              AppLocalizations.get('autoAcceptDesc', locale),
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            value: settings.autoAcceptFiles,
            onChanged: (_) => notifier.toggleAutoAccept(),
          ),

          // Overwrite files
          SwitchListTile(
            secondary: const Icon(Icons.file_copy_outlined),
            title: Text(AppLocalizations.get('overwriteFiles', locale)),
            subtitle: Text(
              AppLocalizations.get('overwriteFilesDesc', locale),
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            value: settings.overwriteFiles,
            onChanged: (_) => notifier.toggleOverwriteFiles(),
          ),

          const Divider(indent: 16, endIndent: 16, height: 24),

          // =================================================================
          // Appearance section
          // =================================================================
          _SectionHeader(
            label: AppLocalizations.get('appearance', locale),
          ),

          // Theme selector
          ListTile(
            leading: const Icon(Icons.palette_outlined),
            title: Text(AppLocalizations.get('appearance', locale)),
            subtitle: Padding(
              padding: const EdgeInsets.only(top: 8),
              child: SegmentedButton<String>(
                segments: [
                  ButtonSegment<String>(
                    value: 'system',
                    label: Text(
                      AppLocalizations.get('systemMode', locale),
                      overflow: TextOverflow.ellipsis,
                    ),
                    icon: const Icon(Icons.brightness_auto, size: 18),
                  ),
                  ButtonSegment<String>(
                    value: 'light',
                    label: Text(
                      AppLocalizations.get('lightMode', locale),
                      overflow: TextOverflow.ellipsis,
                    ),
                    icon: const Icon(Icons.light_mode, size: 18),
                  ),
                  ButtonSegment<String>(
                    value: 'dark',
                    label: Text(
                      AppLocalizations.get('darkMode', locale),
                      overflow: TextOverflow.ellipsis,
                    ),
                    icon: const Icon(Icons.dark_mode, size: 18),
                  ),
                ],
                selected: {settings.theme},
                onSelectionChanged: (selection) {
                  notifier.updateTheme(selection.first);
                },
                showSelectedIcon: false,
              ),
            ),
          ),

          const SizedBox(height: 4),

          // Language selector
          ListTile(
            leading: const Icon(Icons.language),
            title: Text(AppLocalizations.get('language', locale)),
            trailing: DropdownButton<String>(
              value: settings.locale,
              underline: const SizedBox.shrink(),
              borderRadius: BorderRadius.circular(12),
              items: [
                for (final code in AppLocalizations.supportedLocales)
                  DropdownMenuItem(
                    value: code,
                    child: Text(AppLocalizations.localeNames[code] ?? code),
                  ),
              ],
              onChanged: (value) {
                if (value != null) {
                  notifier.updateLocale(value);
                }
              },
            ),
          ),

          // =================================================================
          // Windows section (only on Windows)
          // =================================================================
          if (Platform.isWindows) ...[
            const Divider(indent: 16, endIndent: 16, height: 24),

            _SectionHeader(
              label: AppLocalizations.get('windows', locale),
            ),

            // Launch at startup
            SwitchListTile(
              secondary: const Icon(Icons.rocket_launch_outlined),
              title: Text(
                AppLocalizations.get('launchAtStartup', locale),
              ),
              value: settings.launchAtStartup,
              onChanged: (_) => notifier.toggleLaunchAtStartup(),
            ),

            // Minimize to tray
            SwitchListTile(
              secondary: const Icon(Icons.vertical_align_bottom),
              title: Text(
                AppLocalizations.get('minimizeToTray', locale),
              ),
              value: settings.minimizeToTray,
              onChanged: (_) => notifier.toggleMinimizeToTray(),
            ),

            // Explorer context menu
            SwitchListTile(
              secondary: const Icon(Icons.menu_open),
              title: Text(
                AppLocalizations.get('explorerMenu', locale),
              ),
              value: settings.showInExplorerMenu,
              onChanged: (_) => notifier.toggleExplorerMenu(),
            ),
          ],

          const Divider(indent: 16, endIndent: 16, height: 24),

          // =================================================================
          // About section
          // =================================================================
          _SectionHeader(
            label: AppLocalizations.get('about', locale),
          ),

          ListTile(
            leading: const Icon(Icons.help_outline),
            title: Text(AppLocalizations.get('help', locale)),
            trailing: const Icon(Icons.chevron_right, size: 20),
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => HelpScreen(locale: locale),
                ),
              );
            },
          ),

          ListTile(
            leading: const Icon(Icons.info_outline),
            title: Text(AppLocalizations.get('about', locale)),
            subtitle: Text('${AppLocalizations.get('version', locale)} ${AppConstants.appVersion}'),
            trailing: const Icon(Icons.chevron_right, size: 20),
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => AboutScreen(locale: locale),
                ),
              );
            },
          ),
        ],
      ),
      ),
    );
  }

  // -----------------------------------------------------------------------
  // Device name edit dialog
  // -----------------------------------------------------------------------

  Future<void> _showDeviceNameDialog(
    BuildContext context,
    String currentName,
    SettingsNotifier notifier,
    String locale,
  ) async {
    final controller = TextEditingController(text: currentName);

    final result = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(AppLocalizations.get('deviceName', locale)),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: InputDecoration(
              hintText: AppLocalizations.get('enterDeviceName', locale),
            ),
            onSubmitted: (value) => Navigator.of(context).pop(value),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(AppLocalizations.get('cancel', locale)),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(controller.text),
              child: Text(AppLocalizations.get('save', locale)),
            ),
          ],
        );
      },
    );

    controller.dispose();

    if (result != null && result.trim().isNotEmpty) {
      await notifier.updateDeviceName(result.trim());
    }
  }

  // -----------------------------------------------------------------------
  // Download path picker
  // -----------------------------------------------------------------------

  Future<void> _pickDownloadPath(
    BuildContext context,
    SettingsNotifier notifier,
    String locale,
  ) async {
    // On Android TV, file_picker's directory picker doesn't work (no UI).
    // Show a text input dialog with common path suggestions instead.
    if (Platform.isAndroid && TvDetector.isTVCached) {
      await _showPathInputDialog(context, notifier, locale);
      return;
    }

    // Ensure storage permission on Android before opening picker.
    if (Platform.isAndroid) {
      final hasPermission = await _ensureStoragePermission(context, locale);
      if (!hasPermission) return;
    }

    final selectedDirectory = await FilePicker.platform.getDirectoryPath();
    if (selectedDirectory != null) {
      await notifier.updateDownloadPath(selectedDirectory);
    }
  }

  // -----------------------------------------------------------------------
  // Storage permission helper (Android)
  // -----------------------------------------------------------------------

  Future<bool> _ensureStoragePermission(
    BuildContext context,
    String locale,
  ) async {
    // Check MANAGE_EXTERNAL_STORAGE first (Android 11+).
    var status = await Permission.manageExternalStorage.status;
    if (status.isGranted) return true;

    // Try requesting it.
    status = await Permission.manageExternalStorage.request();
    if (status.isGranted) return true;

    // Fallback: classic storage permission.
    var storageStatus = await Permission.storage.status;
    if (storageStatus.isGranted) return true;

    storageStatus = await Permission.storage.request();
    if (storageStatus.isGranted) return true;

    // Permission denied — show a snackbar guiding user to settings.
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppLocalizations.get('storagePermissionDesc', locale)),
          action: SnackBarAction(
            label: AppLocalizations.get('openSettings', locale),
            onPressed: () => openAppSettings(),
          ),
        ),
      );
    }
    return false;
  }

  // -----------------------------------------------------------------------
  // Manual path input dialog (for Android TV)
  // -----------------------------------------------------------------------

  Future<void> _showPathInputDialog(
    BuildContext context,
    SettingsNotifier notifier,
    String locale,
  ) async {
    final controller = TextEditingController();

    // Common Android storage paths.
    const commonPaths = [
      '/storage/emulated/0/Download',
      '/storage/emulated/0/Documents',
      '/storage/emulated/0',
      '/sdcard/Download',
    ];

    final result = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(AppLocalizations.get('saveLocation', locale)),
          content: SizedBox(
            width: double.maxFinite,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: controller,
                  autofocus: true,
                  decoration: InputDecoration(
                    hintText: AppLocalizations.get('folderPathHint', locale),
                    labelText: AppLocalizations.get('enterPath', locale),
                  ),
                  onSubmitted: (value) => Navigator.of(context).pop(value),
                ),
                const SizedBox(height: 16),
                Text(
                  AppLocalizations.get('commonPaths', locale),
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 8),
                ...commonPaths.map(
                  (path) => InkWell(
                    onTap: () => Navigator.of(context).pop(path),
                    borderRadius: BorderRadius.circular(8),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        vertical: 10,
                        horizontal: 8,
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.folder_outlined, size: 20),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              path,
                              style: Theme.of(context).textTheme.bodyMedium,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(AppLocalizations.get('cancel', locale)),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(controller.text),
              child: Text(AppLocalizations.get('save', locale)),
            ),
          ],
        );
      },
    );

    controller.dispose();

    if (result != null && result.trim().isNotEmpty) {
      final dir = Directory(result.trim());
      if (await dir.exists()) {
        await notifier.updateDownloadPath(result.trim());
      } else {
        // Try to create the directory.
        try {
          await dir.create(recursive: true);
          await notifier.updateDownloadPath(result.trim());
        } catch (_) {
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  AppLocalizations.get('invalidPath', locale),
                ),
              ),
            );
          }
        }
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Section header widget
// ---------------------------------------------------------------------------

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Text(
        label,
        style: theme.textTheme.titleSmall?.copyWith(
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
