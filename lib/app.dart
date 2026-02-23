import 'dart:async';
import 'dart:io';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:window_manager/window_manager.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:anyware/core/constants.dart';
import 'package:anyware/core/logger.dart';
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
import 'package:anyware/features/platform/tray_service.dart';
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

class _MainShell extends ConsumerStatefulWidget {
  const _MainShell();

  @override
  ConsumerState<_MainShell> createState() => _MainShellState();
}

class _MainShellState extends ConsumerState<_MainShell> with WindowListener {
  int _selectedIndex = 0;
  bool _localeInitialized = false;
  bool _sidebarCollapsed = false;

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
    });
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
      ]).timeout(const Duration(seconds: 4), onTimeout: () {
        log.warning('Service shutdown timed out after 4 s');
        return <void>[];
      });
    } catch (e) {
      log.error('Error during service shutdown', error: e);
    }

    // Flush and close the logger file sink.
    try {
      await AppLogger.dispose()
          .timeout(const Duration(seconds: 1), onTimeout: () {});
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
              setState(
                  () => _sidebarCollapsed = !_sidebarCollapsed);
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
    // Compute badges from providers.
    final transfers = ref.watch(activeTransfersProvider);
    final activeTransferCount =
        transfers.where((t) => t.isActive).length;
    final syncState = ref.watch(syncServiceProvider);
    final serverSyncState = ref.watch(serverSyncServiceProvider);
    final activeSyncCount = syncState.jobs.where((j) => j.isActive).length +
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
                  isCollapsed: _sidebarCollapsed,
                  onToggleCollapse: () =>
                      setState(() => _sidebarCollapsed = !_sidebarCollapsed),
                  badges: badges.isNotEmpty ? badges : null,
                ),

                // Content area + status bar
                Expanded(
                  child: Column(
                    children: [
                      Expanded(
                        child: DesktopShellScope(
                          child: IndexedStack(
                            index: _selectedIndex,
                            children: _screens,
                          ),
                        ),
                      ),
                      const DesktopStatusBar(),
                    ],
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
    final List<String> navLabels;
    final List<IconData> navIcons;

    if (_isTV) {
      // TV: 3 tabs — Devices, Transfers, Settings
      navLabels = [
        AppLocalizations.get('devices', locale),
        AppLocalizations.get('transfers', locale),
        AppLocalizations.get('settings', locale),
      ];
      navIcons = [
        Icons.devices_rounded,
        Icons.swap_horiz_rounded,
        Icons.settings_rounded,
      ];
    } else {
      // Mobile: 6 tabs
      navLabels = [
        AppLocalizations.get('devices', locale),
        AppLocalizations.get('transfers', locale),
        AppLocalizations.get('clipboard', locale),
        AppLocalizations.get('folderSync', locale),
        AppLocalizations.get('serverSync', locale),
        AppLocalizations.get('settings', locale),
      ];
      navIcons = [
        Icons.devices_rounded,
        Icons.swap_horiz_rounded,
        Icons.content_paste_rounded,
        Icons.sync_rounded,
        Icons.cloud_sync_rounded,
        Icons.settings_rounded,
      ];
    }

    return Scaffold(
      body: IndexedStack(
        index: _selectedIndex,
        children: _screens,
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedIndex,
        onDestinationSelected: (int index) {
          setState(() => _selectedIndex = index);
        },
        labelBehavior: NavigationDestinationLabelBehavior.alwaysHide,
        height: 56,
        destinations: [
          for (int i = 0; i < navLabels.length; i++)
            NavigationDestination(
              icon: Icon(navIcons[i]),
              label: navLabels[i],
            ),
        ],
      ),
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
    final bgColor = isDark ? const Color(0xFF1E1E2E) : const Color(0xFFF5F5F7);
    final iconColor = isDark ? Colors.white70 : Colors.black54;

    return Container(
      height: 32,
      color: bgColor,
      child: Row(
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
