import 'dart:async';
import 'dart:io';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:window_manager/window_manager.dart';
import 'package:desktop_drop/desktop_drop.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:anyware/core/background_service.dart';
import 'package:anyware/core/constants.dart';
import 'package:anyware/core/file_picker_helper.dart';
import 'package:anyware/core/logger.dart';
import 'package:anyware/core/responsive.dart';
import 'package:anyware/core/theme.dart';
import 'package:anyware/core/tv_detector.dart';
import 'package:anyware/features/settings/presentation/providers.dart';
import 'package:anyware/features/dashboard/presentation/dashboard_screen.dart';
import 'package:anyware/features/discovery/presentation/device_list_screen.dart';
import 'package:anyware/features/discovery/presentation/providers.dart';
import 'package:anyware/features/transfer/presentation/transfer_screen.dart';
import 'package:anyware/features/transfer/presentation/providers.dart';
import 'package:anyware/features/transfer/domain/transfer.dart';
import 'package:anyware/features/settings/presentation/settings_screen.dart';
import 'package:anyware/i18n/app_localizations.dart';
import 'package:anyware/widgets/tv_sidebar.dart';
import 'package:anyware/widgets/desktop_content_shell.dart';
import 'package:anyware/widgets/desktop_status_bar.dart';
import 'package:anyware/features/clipboard/presentation/clipboard_screen.dart';
import 'package:anyware/features/sync/presentation/sync_screen.dart';
import 'package:anyware/features/sync/presentation/sync_setup_dialog.dart';
import 'package:anyware/features/sync/data/sync_service.dart';
import 'package:anyware/features/sync/domain/sync_state.dart';
import 'package:anyware/features/server_sync/presentation/server_sync_screen.dart';
import 'package:anyware/features/server_sync/data/server_sync_service.dart';
import 'package:anyware/features/sharing/presentation/share_target_picker.dart';
import 'package:anyware/features/sharing/data/dropped_file_expander.dart';
import 'package:anyware/features/platform/tray_service.dart';
import 'package:anyware/features/platform/linux/linux_firewall_service.dart';
import 'package:anyware/features/settings/data/settings_repository.dart';
import 'package:anyware/widgets/app_states.dart';

class App extends ConsumerWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);

    // Eagerly start the file server so it is always listening for incoming
    // transfers, even when the Transfers tab is not active.
    ref.watch(fileServerProvider);

    // Eagerly start Android Direct Share so discovered devices appear in
    // the system share sheet.
    if (Platform.isAndroid) {
      ref.watch(directShareProvider);
    }

    final ThemeMode themeMode;
    switch (settings.theme) {
      case 'light':
        themeMode = ThemeMode.light;
      case 'dark':
        themeMode = ThemeMode.dark;
      default:
        themeMode = ThemeMode.system;
    }

    return WithForegroundTask(
      child: MaterialApp(
        title: AppConstants.appName,
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light,
        darkTheme: AppTheme.dark,
        themeMode: themeMode,
        // Bound extreme values while preserving accessibility scaling.
        builder: (context, child) {
          return Directionality(
            textDirection: AppLocalizations.textDirectionFor(settings.locale),
            child: MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: MediaQuery.of(
                  context,
                ).textScaler.clamp(minScaleFactor: 1.0, maxScaleFactor: 2.0),
              ),
              child: child!,
            ),
          );
        },
        shortcuts: <ShortcutActivator, Intent>{
          ...WidgetsApp.defaultShortcuts,
          const SingleActivator(LogicalKeyboardKey.browserBack):
              const _PopRouteIntent(),
          const SingleActivator(LogicalKeyboardKey.escape):
              const _PopRouteIntent(),
        },
        home: const _MainShell(),
      ),
    );
  }
}

class _PopRouteIntent extends Intent {
  const _PopRouteIntent();
}

class _NavIntent extends Intent {
  const _NavIntent(this.index);
  final int index;
}

class _ToggleSidebarIntent extends Intent {
  const _ToggleSidebarIntent();
}

class _QuickShareIntent extends Intent {
  const _QuickShareIntent();
}

class _MainShell extends ConsumerStatefulWidget {
  const _MainShell();

  @override
  ConsumerState<_MainShell> createState() => _MainShellState();
}

class _MainShellState extends ConsumerState<_MainShell> with WindowListener {
  int _selectedIndex = 0;
  bool _localeInitialized = false;

  /// Null follows the responsive default; once the user presses the toggle,
  /// their explicit choice wins even on a narrower desktop window.
  bool? _sidebarCollapsedOverride;
  bool _isGlobalDragging = false;

  /// Whether the device is an Android TV.
  bool get _isTV => Platform.isAndroid && TvDetector.isTVCached;

  /// Use sidebar layout on desktop platforms (TV uses bottom nav).
  bool get _useSidebar =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  /// Screen list based on platform.
  List<Widget> get _screens {
    // TV: simplified — Dashboard, Transfers, Settings
    if (_isTV) {
      return const <Widget>[
        DashboardScreen(),
        TransferScreen(),
        SettingsScreen(),
      ];
    }
    // Desktop sidebar: Dashboard, Transfers, Clipboard, Sync, ServerSync, Settings
    if (_useSidebar) {
      return const <Widget>[
        DashboardScreen(),
        TransferScreen(),
        ClipboardScreen(),
        SyncScreen(),
        ServerSyncScreen(),
        SettingsScreen(),
      ];
    }
    // Mobile: DeviceList, Transfers, Clipboard, Sync, ServerSync, Settings
    return const <Widget>[
      DeviceListScreen(),
      TransferScreen(),
      ClipboardScreen(),
      SyncScreen(),
      ServerSyncScreen(),
      SettingsScreen(),
    ];
  }

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initLocaleIfNeeded();
      if (Platform.isLinux) {
        unawaited(_checkLinuxFirewall());
      }
    });
  }

  Future<void> _checkLinuxFirewall() async {
    final service = LinuxFirewallService(ref.read(sharedPreferencesProvider));
    final check = await service.inspect();
    if (!mounted) return;

    if (check.state == LinuxFirewallState.unavailable) {
      AppLogger(
        'LinuxFirewall',
      ).warning('Active firewall detected but pkexec/helper is unavailable.');
      return;
    }
    if (check.state != LinuxFirewallState.needsAuthorization) return;

    final locale = ref.read(settingsProvider).locale;
    final approved = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        final theme = Theme.of(dialogContext);
        return AlertDialog(
          icon: Icon(
            Icons.shield_outlined,
            color: theme.colorScheme.primary,
            size: 36,
          ),
          title: Text(
            AppLocalizations.get('linuxFirewallTitle', locale),
            textAlign: TextAlign.center,
          ),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(AppLocalizations.get('linuxFirewallDescription', locale)),
                const SizedBox(height: 14),
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          Icons.lan_outlined,
                          color: theme.colorScheme.primary,
                          size: 20,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            AppLocalizations.get('linuxFirewallScope', locale),
                            style: theme.textTheme.bodySmall,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(AppLocalizations.get('notNow', locale)),
            ),
            FilledButton.icon(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              icon: const Icon(Icons.lock_open_rounded),
              label: Text(AppLocalizations.get('linuxFirewallAllow', locale)),
            ),
          ],
        );
      },
    );

    if (approved != true) {
      await service.deferPrompt();
      return;
    }

    final result = await service.configure(check);
    if (!mounted) return;

    final messageKey = result.success
        ? 'linuxFirewallSuccess'
        : 'linuxFirewallFailed';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(AppLocalizations.get(messageKey, locale))),
    );

    if (result.success) {
      await ref.read(refreshDiscoveryProvider)();
    } else if (result.details.isNotEmpty) {
      AppLogger(
        'LinuxFirewall',
      ).warning('Firewall setup failed: ${result.details}');
    }
  }

  @override
  void onWindowClose() async {
    final isDesktop =
        Platform.isWindows || Platform.isLinux || Platform.isMacOS;
    if (!isDesktop) return;

    final settings = ref.read(settingsProvider);
    final isTrayExit = AppTrayService.exitRequested;

    // If minimize-to-tray is enabled AND this is a normal close (not tray
    // "Exit"), just hide the window and keep running.
    if (settings.minimizeToTray && !isTrayExit) {
      await windowManager.hide();
      return;
    }

    // If this is NOT a tray exit, show a sync warning dialog if sync is active.
    if (!isTrayExit) {
      final syncState = ref.read(syncServiceProvider);
      final serverSyncState = ref.read(serverSyncServiceProvider);
      if ((syncState.hasActiveJobs || serverSyncState.activeJobCount > 0) &&
          mounted) {
        final locale = settings.locale;
        final shouldClose = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(AppLocalizations.get('folderSync', locale)),
            content: Text(AppLocalizations.get('syncExitWarning', locale)),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: Text(AppLocalizations.get('syncExitCancel', locale)),
              ),
              FilledButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: Text(AppLocalizations.get('syncExitConfirm', locale)),
              ),
            ],
          ),
        );
        if (shouldClose != true) return;
      }
    }

    // ── Shutdown with hard timeout ──────────────────────────────────────────
    // If anything hangs, the safety timer will force-kill the process.
    final safetyTimer = Timer(const Duration(seconds: 6), () => exit(0));

    try {
      await _shutdownServices();
    } catch (_) {}

    safetyTimer.cancel();
    await windowManager.setPreventClose(false);
    await windowManager.destroy();
    exit(0);
  }

  /// Stops all background services and flushes the logger.
  ///
  /// Individual operations are wrapped in a 4-second total timeout so a
  /// blocked socket or file watcher cannot hold up the shutdown.
  Future<void> _shutdownServices() async {
    final log = AppLogger('Shutdown');
    log.info('Shutting down services…');

    try {
      await Future.wait<void>([
        Future<void>.sync(() {
          ref.read(discoveryServiceProvider).valueOrNull?.stop();
        }),
        Future<void>.sync(() {
          try {
            ref.read(syncServiceProvider.notifier).stopAll();
          } catch (_) {}
        }),
        Future<void>.sync(() {
          try {
            ref.read(serverSyncServiceProvider.notifier).stopAll();
          } catch (_) {}
        }),
        (ref.read(fileServerProvider).valueOrNull?.stop() ?? Future.value())
            .timeout(const Duration(seconds: 3), onTimeout: () {}),
      ]).timeout(
        const Duration(seconds: 4),
        onTimeout: () {
          log.warning('Service shutdown timed out after 4 s');
          return <void>[];
        },
      );
    } catch (e) {
      log.error('Error during service shutdown', error: e);
    }

    // Flush and close the logger file sink.
    try {
      await AppLogger.dispose().timeout(
        const Duration(seconds: 1),
        onTimeout: () {},
      );
    } catch (_) {}
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  void _initLocaleIfNeeded() {
    if (_localeInitialized) return;
    _localeInitialized = true;

    final settings = ref.read(settingsProvider);
    final detected = AppLocalizations.detectLocale();
    if (detected != settings.locale && settings.deviceName.isEmpty) {
      ref.read(settingsProvider.notifier).updateLocale(detected);
    }
  }

  void _navigateToTransfers() {
    if (_selectedIndex != 1) {
      setState(() => _selectedIndex = 1);
    }
  }

  Future<void> _shareDroppedPaths(List<String> rawPaths, String locale) async {
    final filePaths = await expandDroppedPaths(rawPaths);
    if (!mounted || filePaths.isEmpty) return;

    final devices = ref.read(devicesProvider).valueOrNull ?? const [];
    final accounts = ref.read(serverSyncServiceProvider).accounts;
    if (devices.isEmpty && accounts.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppLocalizations.get('noDevices', locale))),
      );
      return;
    }

    final selection = await showShareTargetPicker(
      context: context,
      devices: devices,
      accounts: accounts,
      filePaths: filePaths,
      locale: locale,
    );
    if (selection == null || !mounted) return;

    final selected = selection.target;
    final selectedPaths = selection.filePaths;
    if (selected is DeviceShareTarget) {
      final queue = await ref.read(transferQueueProvider.future);
      queue.enqueueAll(selected.device, selectedPaths);
      if (mounted) _navigateToTransfers();
    } else if (selected is AccountShareTarget) {
      final account = selected.account;
      final remoteDir = account.remotePath.isEmpty ? '/' : account.remotePath;
      final service = ref.read(serverSyncServiceProvider.notifier);
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => ServerUploadProgressDialog(
          stream: service.uploadFilesToAccount(
            account.id,
            selectedPaths,
            remoteDir,
          ),
          totalFiles: selectedPaths.length,
          serverName: account.name,
          locale: locale,
        ),
      );
    }
  }

  Future<void> _openQuickShare(String locale) async {
    final result = await FilePickerHelper.pickFiles(allowMultiple: true);
    if (!mounted || result == null) return;
    final paths = result.files.map((file) => file.path).whereType<String>();
    await _shareDroppedPaths(paths.toList(), locale);
  }

  Widget _buildGlobalDropSurface(String locale, Widget child) {
    return DropTarget(
      onDragEntered: (_) => setState(() => _isGlobalDragging = true),
      onDragExited: (_) => setState(() => _isGlobalDragging = false),
      onDragDone: (details) {
        setState(() => _isGlobalDragging = false);
        final paths = details.files.map((file) => file.path).toList();
        if (paths.isNotEmpty) {
          _shareDroppedPaths(paths, locale);
        }
      },
      child: Stack(
        children: [
          Positioned.fill(child: child),
          Positioned.fill(
            child: IgnorePointer(
              child: AnimatedSwitcher(
                duration: context.motionDuration(AppMotion.standard),
                child: _isGlobalDragging
                    ? AppDropOverlay(
                        key: const ValueKey('global-drop-overlay'),
                        label: AppLocalizations.get('dropFilesHere', locale),
                      )
                    : const SizedBox.shrink(
                        key: ValueKey('global-drop-overlay-hidden'),
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _toggleSidebar() {
    final autoCollapsed =
        MediaQuery.sizeOf(context).width < AppBreakpoints.expanded;
    final currentlyCollapsed = _sidebarCollapsedOverride ?? autoCollapsed;
    setState(() => _sidebarCollapsedOverride = !currentlyCollapsed);
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final locale = settings.locale;

    // Auto-switch to Transfer screen when a new incoming transfer arrives.
    ref.listen<List<Transfer>>(activeTransfersProvider, (prev, next) {
      final prevIds = prev?.map((t) => t.id).toSet() ?? {};
      final hasNewTransfer = next.any((t) => !prevIds.contains(t.id));
      if (hasNewTransfer && next.any((t) => t.isActive)) {
        _navigateToTransfers();
      }
    });

    // Show sync setup dialog when a remote device sends a setup request.
    ref.listen<SyncState>(syncServiceProvider, (prev, next) {
      if (next.pendingSyncSetup != null &&
          prev?.pendingSyncSetup == null &&
          mounted) {
        showDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (_) => SyncSetupDialog(request: next.pendingSyncSetup!),
        );
      }
    });

    // Update persistent notification text when the locale changes (Android).
    if (Platform.isAndroid) {
      BackgroundTransferService.instance.updatePersistentNotifStrings(
        title: AppLocalizations.get('notifPersistentTitle', locale),
        text: AppLocalizations.get('notifPersistentText', locale),
      );
    }

    final screenCount = _screens.length;

    return Shortcuts(
      shortcuts: <ShortcutActivator, Intent>{
        // Ctrl+1..6 → navigate to specific tab (desktop only)
        if (_useSidebar) ...{
          const SingleActivator(LogicalKeyboardKey.digit1, control: true):
              _NavIntent(0),
          const SingleActivator(LogicalKeyboardKey.digit2, control: true):
              _NavIntent(1),
          if (screenCount > 2)
            const SingleActivator(LogicalKeyboardKey.digit3, control: true):
                _NavIntent(2),
          if (screenCount > 3)
            const SingleActivator(LogicalKeyboardKey.digit4, control: true):
                _NavIntent(3),
          if (screenCount > 4)
            const SingleActivator(LogicalKeyboardKey.digit5, control: true):
                _NavIntent(4),
          if (screenCount > 5)
            const SingleActivator(LogicalKeyboardKey.digit6, control: true):
                _NavIntent(5),
          const SingleActivator(LogicalKeyboardKey.bracketLeft, control: true):
              const _ToggleSidebarIntent(),
          const SingleActivator(
            LogicalKeyboardKey.keyS,
            control: true,
            shift: true,
          ): const _QuickShareIntent(),
        },
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          _PopRouteIntent: CallbackAction<_PopRouteIntent>(
            onInvoke: (_) {
              final navigator = Navigator.of(context);
              if (navigator.canPop()) {
                navigator.pop();
              }
              return null;
            },
          ),
          _NavIntent: CallbackAction<_NavIntent>(
            onInvoke: (intent) {
              if (intent.index < screenCount) {
                setState(() => _selectedIndex = intent.index);
              }
              return null;
            },
          ),
          _ToggleSidebarIntent: CallbackAction<_ToggleSidebarIntent>(
            onInvoke: (_) {
              _toggleSidebar();
              return null;
            },
          ),
          _QuickShareIntent: CallbackAction<_QuickShareIntent>(
            onInvoke: (_) {
              unawaited(_openQuickShare(locale));
              return null;
            },
          ),
        },
        child: _useSidebar
            ? _buildSidebarLayout(locale)
            : _buildBottomNavLayout(locale),
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Sidebar layout (Windows, Linux, macOS)
  // ─────────────────────────────────────────────────────────────────────────

  Widget _buildSidebarLayout(String locale) {
    final autoCollapsed =
        MediaQuery.sizeOf(context).width < AppBreakpoints.expanded;
    final isSidebarCollapsed = _sidebarCollapsedOverride ?? autoCollapsed;

    // Compute badges from providers.
    final transfers = ref.watch(activeTransfersProvider);
    final activeTransferCount = transfers.where((t) => t.isActive).length;
    final syncState = ref.watch(syncServiceProvider);
    final serverSyncState = ref.watch(serverSyncServiceProvider);
    final activeSyncCount =
        syncState.jobs.where((j) => j.isActive).length +
        serverSyncState.jobs.where((j) => j.isActive).length;

    final badges = <int, String>{
      if (activeTransferCount > 0) 1: '$activeTransferCount',
      if (activeSyncCount > 0) 3: '$activeSyncCount',
    };

    return Scaffold(
      body: Column(
        children: [
          // Custom titlebar (Windows only)
          if (Platform.isWindows) const _WindowsTitleBar(),

          // Main content
          Expanded(
            child: Row(
              children: [
                // Left sidebar
                TvSidebar(
                  selectedIndex: _selectedIndex,
                  onIndexChanged: (i) => setState(() => _selectedIndex = i),
                  locale: locale,
                  isTv: false,
                  isCollapsed: isSidebarCollapsed,
                  onToggleCollapse: _toggleSidebar,
                  badges: badges.isNotEmpty ? badges : null,
                ),

                // Content area + status bar
                Expanded(
                  child: _selectedIndex == 0
                      ? _DesktopBackdrop(
                          child: Column(
                            children: [
                              Expanded(
                                child: DesktopShellScope(
                                  child: _AnimatedIndexedStack(
                                    index: _selectedIndex,
                                    children: _screens,
                                  ),
                                ),
                              ),
                              const DesktopStatusBar(),
                            ],
                          ),
                        )
                      : _buildGlobalDropSurface(
                          locale,
                          _DesktopBackdrop(
                            child: Column(
                              children: [
                                Expanded(
                                  child: DesktopShellScope(
                                    child: _AnimatedIndexedStack(
                                      index: _selectedIndex,
                                      children: _screens,
                                    ),
                                  ),
                                ),
                                const DesktopStatusBar(),
                              ],
                            ),
                          ),
                        ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Bottom nav layout (Android phone, iOS, Android TV)
  // ─────────────────────────────────────────────────────────────────────────

  Widget _buildBottomNavLayout(String locale) {
    if (_isTV) {
      final navLabels = [
        AppLocalizations.get('devices', locale),
        AppLocalizations.get('transfers', locale),
        AppLocalizations.get('settings', locale),
      ];
      final navIcons = [
        Icons.devices_rounded,
        Icons.swap_horiz_rounded,
        Icons.settings_rounded,
      ];

      final extended = MediaQuery.sizeOf(context).width >= 1100;
      return Scaffold(
        body: SafeArea(
          child: Row(
            children: [
              NavigationRail(
                extended: extended,
                minWidth: 88,
                minExtendedWidth: 220,
                groupAlignment: -0.55,
                selectedIndex: _selectedIndex,
                labelType: extended
                    ? NavigationRailLabelType.none
                    : NavigationRailLabelType.all,
                onDestinationSelected: (index) {
                  setState(() => _selectedIndex = index);
                },
                destinations: [
                  for (int i = 0; i < navLabels.length; i++)
                    NavigationRailDestination(
                      icon: Icon(navIcons[i]),
                      selectedIcon: Icon(navIcons[i]),
                      label: Text(navLabels[i]),
                    ),
                ],
              ),
              const VerticalDivider(width: 1),
              Expanded(
                child: FocusTraversalGroup(
                  policy: ReadingOrderTraversalPolicy(),
                  child: _AnimatedIndexedStack(
                    index: _selectedIndex,
                    children: _screens,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    final navLabels = [
      AppLocalizations.get('devices', locale),
      AppLocalizations.get('transfers', locale),
      AppLocalizations.get('clipboard', locale),
      AppLocalizations.get('more', locale),
    ];
    const navIcons = [
      Icons.devices_rounded,
      Icons.swap_horiz_rounded,
      Icons.content_paste_rounded,
      Icons.more_horiz_rounded,
    ];

    return Scaffold(
      body: _AnimatedIndexedStack(index: _selectedIndex, children: _screens),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedIndex <= 2 ? _selectedIndex : 3,
        onDestinationSelected: (int index) {
          if (index == 3) {
            _showMoreDestinations(locale);
          } else {
            setState(() => _selectedIndex = index);
          }
        },
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        height: 64,
        destinations: [
          for (int i = 0; i < navLabels.length; i++)
            NavigationDestination(icon: Icon(navIcons[i]), label: navLabels[i]),
        ],
      ),
    );
  }

  Future<void> _showMoreDestinations(String locale) async {
    final selected = await showModalBottomSheet<int>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      builder: (sheetContext) => Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.sync_rounded),
              title: Text(AppLocalizations.get('folderSync', locale)),
              selected: _selectedIndex == 3,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              onTap: () => Navigator.of(sheetContext).pop(3),
            ),
            ListTile(
              leading: const Icon(Icons.cloud_sync_rounded),
              title: Text(AppLocalizations.get('serverSync', locale)),
              selected: _selectedIndex == 4,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              onTap: () => Navigator.of(sheetContext).pop(4),
            ),
            ListTile(
              leading: const Icon(Icons.settings_rounded),
              title: Text(AppLocalizations.get('settings', locale)),
              selected: _selectedIndex == 5,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              onTap: () => Navigator.of(sheetContext).pop(5),
            ),
          ],
        ),
      ),
    );

    if (selected != null && mounted) {
      setState(() => _selectedIndex = selected);
    }
  }
}

/// Adds a subtle ambient layer so desktop pages do not read as a flat sheet.
class _DesktopBackdrop extends StatelessWidget {
  const _DesktopBackdrop({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ColoredBox(color: theme.scaffoldBackgroundColor, child: child);
  }
}

/// Keeps every destination alive while softly transitioning between pages.
class _AnimatedIndexedStack extends StatelessWidget {
  const _AnimatedIndexedStack({required this.index, required this.children});

  final int index;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final duration = context.motionDuration(AppMotion.standard);
    return Stack(
      fit: StackFit.expand,
      children: [
        for (int i = 0; i < children.length; i++)
          AnimatedOpacity(
            key: ValueKey(i),
            opacity: i == index ? 1 : 0,
            duration: duration,
            curve: Curves.easeOutCubic,
            child: AnimatedSlide(
              offset: i == index ? Offset.zero : const Offset(0.015, 0),
              duration: duration,
              curve: Curves.easeOutCubic,
              child: IgnorePointer(
                ignoring: i != index,
                child: ExcludeSemantics(
                  excluding: i != index,
                  child: TickerMode(enabled: i == index, child: children[i]),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Custom Windows titlebar with drag-to-move and window controls
// ---------------------------------------------------------------------------

class _WindowsTitleBar extends StatelessWidget {
  const _WindowsTitleBar();

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = isDark ? AppColors.darkSurface : AppColors.lightSidebar;
    final iconColor = isDark
        ? AppColors.textSecondary
        : AppColors.lightTextSecondary;

    return Container(
      height: 32,
      color: bgColor,
      child: Row(
        textDirection: TextDirection.ltr,
        children: [
          // Draggable area (title)
          Expanded(
            child: DragToMoveArea(
              child: Padding(
                padding: const EdgeInsets.only(left: 12),
                child: Text(
                  'LifeOS AnyWhere',
                  style: TextStyle(
                    fontSize: 12,
                    color: iconColor,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ),
          ),

          // Minimize
          _TitleBarButton(
            icon: Icons.minimize,
            iconColor: iconColor,
            onPressed: () => windowManager.minimize(),
          ),

          // Maximize / Restore
          _TitleBarButton(
            icon: Icons.crop_square,
            iconColor: iconColor,
            onPressed: () async {
              if (await windowManager.isMaximized()) {
                await windowManager.unmaximize();
              } else {
                await windowManager.maximize();
              }
            },
          ),

          // Close
          _TitleBarButton(
            icon: Icons.close,
            iconColor: iconColor,
            hoverColor: Colors.red,
            onPressed: () => windowManager.close(),
          ),
        ],
      ),
    );
  }
}

class _TitleBarButton extends StatefulWidget {
  const _TitleBarButton({
    required this.icon,
    required this.iconColor,
    required this.onPressed,
    this.hoverColor,
  });

  final IconData icon;
  final Color iconColor;
  final VoidCallback onPressed;
  final Color? hoverColor;

  @override
  State<_TitleBarButton> createState() => _TitleBarButtonState();
}

class _TitleBarButtonState extends State<_TitleBarButton> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: GestureDetector(
        onTap: widget.onPressed,
        child: Container(
          width: 46,
          height: 32,
          color: _isHovered
              ? (widget.hoverColor ?? Colors.white.withValues(alpha: 0.1))
              : Colors.transparent,
          child: Icon(
            widget.icon,
            size: 16,
            color: _isHovered && widget.hoverColor != null
                ? Colors.white
                : widget.iconColor,
          ),
        ),
      ),
    );
  }
}
