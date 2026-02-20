import 'dart:io';

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
import 'package:anyware/features/clipboard/presentation/clipboard_screen.dart';
import 'package:anyware/features/sync/presentation/sync_screen.dart';
import 'package:anyware/features/sync/data/sync_service.dart';

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

    return MaterialApp(
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
    );
  }
}

class _PopRouteIntent extends Intent {
  const _PopRouteIntent();
}

class _MainShell extends ConsumerStatefulWidget {
  const _MainShell();

  @override
  ConsumerState<_MainShell> createState() => _MainShellState();
}

class _MainShellState extends ConsumerState<_MainShell> with WindowListener {
  int _selectedIndex = 0;
  bool _localeInitialized = false;

  /// Android TV mi?
  bool get _isTV => Platform.isAndroid && TvDetector.isTVCached;

  /// Masaüstü platformlarda sidebar kullan (TV hariç — TV bottom nav kullanır).
  bool get _useSidebar =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  /// Ekran listesi.
  List<Widget> get _screens {
    // TV: basit — Dashboard, Transfers, Settings
    if (_isTV) {
      return const <Widget>[
        DashboardScreen(),
        TransferScreen(),
        SettingsScreen(),
      ];
    }
    // Masaüstü sidebar: Dashboard, Transfers, Clipboard, Sync, Settings
    if (_useSidebar) {
      return const <Widget>[
        DashboardScreen(),
        TransferScreen(),
        ClipboardScreen(),
        SyncScreen(),
        SettingsScreen(),
      ];
    }
    // Mobil: DeviceList, Transfers, Clipboard, Sync, Settings
    return const <Widget>[
      DeviceListScreen(),
      TransferScreen(),
      ClipboardScreen(),
      SyncScreen(),
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
    if (isDesktop) {
      // If minimize-to-tray is enabled, just hide the window.
      final settings = ref.read(settingsProvider);
      if (settings.minimizeToTray) {
        await windowManager.hide();
        return;
      }

      // If sync is active, show a warning dialog before closing.
      final syncState = ref.read(syncServiceProvider);
      if (syncState.hasActiveJobs && mounted) {
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

      // Perform a full shutdown.
      try {
        ref.read(discoveryServiceProvider).valueOrNull?.stop();
        try {
          ref.read(syncServiceProvider.notifier).stopAll();
        } catch (_) {}
        await ref.read(fileServerProvider).valueOrNull?.stop();
      } catch (e) {
        AppLogger('MainShell').error('Error during shutdown', error: e);
      }

      await windowManager.setPreventClose(false);
      await windowManager.destroy();
      exit(0);
    }
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

    // Yeni transfer geldiğinde otomatik olarak Transfer ekranına geç.
    ref.listen<List<Transfer>>(activeTransfersProvider, (prev, next) {
      final prevIds = prev?.map((t) => t.id).toSet() ?? {};
      final hasNewTransfer = next.any((t) => !prevIds.contains(t.id));
      if (hasNewTransfer && next.any((t) => t.isActive)) {
        _navigateToTransfers();
      }
    });

    return Actions(
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
      },
      child: _useSidebar
          ? _buildSidebarLayout(locale)
          : _buildBottomNavLayout(locale),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Sidebar düzeni (Windows, Linux, macOS)
  // ─────────────────────────────────────────────────────────────────────────

  Widget _buildSidebarLayout(String locale) {
    return Scaffold(
      body: Column(
        children: [
          // Custom titlebar (Windows only)
          if (Platform.isWindows) const _WindowsTitleBar(),

          // Main content
          Expanded(
            child: Row(
              children: [
                // Sol sidebar
                TvSidebar(
                  selectedIndex: _selectedIndex,
                  onIndexChanged: (i) => setState(() => _selectedIndex = i),
                  locale: locale,
                  isTv: false,
                ),

                // İçerik alanı
                Expanded(
                  child: IndexedStack(
                    index: _selectedIndex,
                    children: _screens,
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
  // Bottom nav düzeni (Android telefon, iOS, Android TV)
  // ─────────────────────────────────────────────────────────────────────────

  Widget _buildBottomNavLayout(String locale) {
    final List<String> navLabels;
    final List<IconData> navIcons;

    if (_isTV) {
      // TV: 3 sekme — Cihazlar, Transferler, Ayarlar
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
      // Mobil: 5 sekme
      navLabels = [
        AppLocalizations.get('devices', locale),
        AppLocalizations.get('transfers', locale),
        AppLocalizations.get('clipboard', locale),
        AppLocalizations.get('folderSync', locale),
        AppLocalizations.get('settings', locale),
      ];
      navIcons = [
        Icons.devices_rounded,
        Icons.swap_horiz_rounded,
        Icons.content_paste_rounded,
        Icons.sync_rounded,
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
