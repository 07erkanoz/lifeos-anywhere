import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:anyware/core/file_picker_helper.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:flutter/services.dart';

import 'package:anyware/core/constants.dart';
import 'package:anyware/core/tv_detector.dart';
import 'package:anyware/features/discovery/presentation/providers.dart';
import 'package:anyware/features/pairing/presentation/providers.dart';
import 'package:anyware/features/settings/presentation/providers.dart';
import 'package:anyware/features/settings/presentation/help_screen.dart';
import 'package:anyware/features/settings/presentation/about_screen.dart';
import 'package:anyware/i18n/app_localizations.dart';
import 'package:anyware/ui/ui_kit.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final notifier = ref.read(settingsProvider.notifier);
    final locale = settings.locale;
    final ui = Ui.of(context);
    final me = ref.watch(localDeviceProvider).valueOrNull;

    Widget toggle({
      required IconData icon,
      required String title,
      String? subtitle,
      required bool value,
      required VoidCallback onChanged,
    }) =>
        SwitchListTile(
          secondary: Icon(icon, color: ui.accentText),
          title: Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
          subtitle: subtitle == null
              ? null
              : Text(subtitle, style: TextStyle(fontSize: 12, color: ui.muted)),
          value: value,
          onChanged: (_) => onChanged(),
        );

    Widget link({
      required IconData icon,
      required String title,
      String? subtitle,
      Widget? trailing,
      VoidCallback? onTap,
    }) =>
        ListTile(
          leading: Icon(icon, color: ui.accentText),
          title: Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
          subtitle: subtitle == null
              ? null
              : Text(subtitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: ui.muted)),
          trailing: trailing ?? (onTap == null ? null : Icon(Icons.chevron_right_rounded, color: ui.muted)),
          onTap: onTap,
        );

    Divider line() => Divider(height: 1, thickness: 1, color: ui.border);

    final body = FocusTraversalGroup(
      policy: OrderedTraversalPolicy(),
      child: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          PageHeader(title: AppLocalizations.get('settings', locale)),

          // This device: its name as paired devices see it.
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 16),
            padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
            decoration: BoxDecoration(
              color: ui.surface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: ui.border),
            ),
            child: Row(
              children: [
                DeviceAvatar(platform: me?.platform ?? Platform.operatingSystem, size: 44),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        settings.deviceName.isNotEmpty ? settings.deviceName : '---',
                        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                      ),
                      Text(AppLocalizations.get('deviceName', locale),
                          style: TextStyle(fontSize: 12, color: ui.muted)),
                    ],
                  ),
                ),
                OutlinedButton(
                  onPressed: () => _showDeviceNameDialog(context, settings.deviceName, notifier, locale),
                  child: Text(AppLocalizations.get('edit', locale)),
                ),
              ],
            ),
          ),

          SectionHeader(AppLocalizations.get('transfer', locale)),
          Panel(children: [
            if (Platform.isAndroid) ...[
              toggle(
                icon: Icons.wifi_tethering_rounded,
                title: AppLocalizations.get('stayReachable', locale),
                subtitle: AppLocalizations.get('stayReachableDesc', locale),
                value: settings.stayReachable,
                onChanged: notifier.toggleStayReachable,
              ),
              line(),
            ],
            toggle(
              icon: Icons.file_download_outlined,
              title: AppLocalizations.get('autoAccept', locale),
              subtitle: AppLocalizations.get('autoAcceptDesc', locale),
              value: settings.autoAcceptFiles,
              onChanged: notifier.toggleAutoAccept,
            ),
            line(),
            toggle(
              icon: Icons.file_copy_outlined,
              title: AppLocalizations.get('overwriteFiles', locale),
              subtitle: AppLocalizations.get('overwriteFilesDesc', locale),
              value: settings.overwriteFiles,
              onChanged: notifier.toggleOverwriteFiles,
            ),
            line(),
            link(
              icon: Icons.folder_outlined,
              title: AppLocalizations.get('saveLocation', locale),
              subtitle: settings.downloadPath.isNotEmpty ? settings.downloadPath : '---',
              trailing: TextButton(
                onPressed: () => _pickDownloadPath(context, notifier, locale),
                child: Text(AppLocalizations.get('chooseFolder', locale)),
              ),
            ),
            line(),
            _WebPortalTile(locale: locale),
          ]),

          SectionHeader(AppLocalizations.get('appearance', locale)),
          Panel(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.palette_outlined, color: ui.accentText),
                      const SizedBox(width: 16),
                      Text(AppLocalizations.get('theme', locale),
                          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
                    ],
                  ),
                  const SizedBox(height: 12),
                  LayoutBuilder(
                    builder: (context, constraints) {
                      const options = [
                        ('system', Icons.brightness_auto_rounded, 'systemMode'),
                        ('light', Icons.light_mode_rounded, 'lightMode'),
                        ('dark', Icons.dark_mode_rounded, 'darkMode'),
                      ];
                      // three segments do not fit a narrow phone: a menu there
                      if (constraints.maxWidth < 430) {
                        return DropdownButton<String>(
                          value: settings.theme,
                          isExpanded: true,
                          underline: const SizedBox.shrink(),
                          borderRadius: BorderRadius.circular(12),
                          items: [
                            for (final (value, icon, key) in options)
                              DropdownMenuItem(
                                value: value,
                                child: Row(children: [
                                  Icon(icon, size: 18),
                                  const SizedBox(width: 10),
                                  Text(AppLocalizations.get(key, locale)),
                                ]),
                              ),
                          ],
                          onChanged: (value) {
                            if (value != null) notifier.updateTheme(value);
                          },
                        );
                      }
                      return SizedBox(
                        width: double.infinity,
                        child: SegmentedButton<String>(
                          segments: [
                            for (final (value, icon, key) in options)
                              ButtonSegment<String>(
                                value: value,
                                icon: Icon(icon, size: 18),
                                label: Text(AppLocalizations.get(key, locale), overflow: TextOverflow.ellipsis),
                              ),
                          ],
                          selected: {settings.theme},
                          onSelectionChanged: (selection) => notifier.updateTheme(selection.first),
                          showSelectedIcon: false,
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
            line(),
            link(
              icon: Icons.language_rounded,
              title: AppLocalizations.get('language', locale),
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
                  if (value != null) notifier.updateLocale(value);
                },
              ),
            ),
          ]),

          if (Platform.isWindows) ...[
            SectionHeader(AppLocalizations.get('windows', locale)),
            Panel(children: [
              toggle(
                icon: Icons.rocket_launch_outlined,
                title: AppLocalizations.get('launchAtStartup', locale),
                value: settings.launchAtStartup,
                onChanged: notifier.toggleLaunchAtStartup,
              ),
              line(),
              toggle(
                icon: Icons.vertical_align_bottom_rounded,
                title: AppLocalizations.get('minimizeToTray', locale),
                value: settings.minimizeToTray,
                onChanged: notifier.toggleMinimizeToTray,
              ),
              line(),
              toggle(
                icon: Icons.menu_open_rounded,
                title: AppLocalizations.get('explorerMenu', locale),
                value: settings.showInExplorerMenu,
                onChanged: notifier.toggleExplorerMenu,
              ),
            ]),
          ],

          SectionHeader(AppLocalizations.get('about', locale)),
          Panel(children: [
            link(
              icon: Icons.install_mobile_rounded,
              title: AppLocalizations.get('installOnOtherDevices', locale),
              subtitle: AppLocalizations.get('installOnOtherDevicesDesc', locale),
              trailing: Icon(Icons.open_in_new_rounded, size: 20, color: ui.muted),
              onTap: () async {
                try {
                  await launchUrl(Uri.parse(AppConstants.websiteUrl), mode: LaunchMode.externalApplication);
                } catch (_) {}
              },
            ),
            line(),
            link(
              icon: Icons.help_outline_rounded,
              title: AppLocalizations.get('help', locale),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => HelpScreen(locale: locale)),
              ),
            ),
            line(),
            link(
              icon: Icons.info_outline_rounded,
              title: AppLocalizations.get('about', locale),
              subtitle: 'AnyWhere ${AppConstants.appVersion}',
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => AboutScreen(locale: locale)),
              ),
            ),
          ]),
        ],
      ),
    );

    return Scaffold(
      backgroundColor: ui.bg,
      body: SafeArea(
        bottom: false,
        child: Center(
          child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 760), child: body),
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

    final selectedDirectory = await FilePickerHelper.getDirectoryPath();
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
                Text(
                  AppLocalizations.get('commonPaths', locale),
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 8),
                ...commonPaths.asMap().entries.map(
                  (entry) => ListTile(
                    autofocus: entry.key == 0,
                    leading: const Icon(Icons.folder_outlined, size: 20),
                    title: Text(
                      entry.value,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                    onTap: () => Navigator.of(context).pop(entry.value),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: controller,
                  decoration: InputDecoration(
                    hintText: AppLocalizations.get('folderPathHint', locale),
                    labelText: AppLocalizations.get('enterPath', locale),
                  ),
                  onSubmitted: (value) => Navigator.of(context).pop(value),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              autofocus: false,
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

class _WebPortalTile extends ConsumerWidget {
  const _WebPortalTile({required this.locale});

  final String locale;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final deviceAsync = ref.watch(localDeviceProvider);
    final ip = deviceAsync.valueOrNull?.ip ?? '...';
    final port = AppConstants.defaultPort;
    final portalKey = ref.watch(trustStoreProvider).portalKey;
    final url = 'http://$ip:$port/portal?k=$portalKey';

    return ListTile(
      leading: const Icon(Icons.language),
      title: Text(AppLocalizations.get('webPortal', locale)),
      subtitle: Text(
        url,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
      trailing: IconButton(
        icon: const Icon(Icons.copy, size: 20),
        tooltip: AppLocalizations.get('copiedToClipboard', locale),
        onPressed: () {
          Clipboard.setData(ClipboardData(text: url));
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(AppLocalizations.get('copiedToClipboard', locale)),
              duration: const Duration(seconds: 1),
            ),
          );
        },
      ),
      onTap: () async {
        try {
          await launchUrl(Uri.parse(url));
        } catch (_) {}
      },
    );
  }
}

