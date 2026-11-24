import 'dart:async';
import 'dart:io';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:window_manager/window_manager.dart';
import 'package:desktop_drop/desktop_drop.dart';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:anyware/features/esitleme/presentation/providers.dart';
import 'package:anyware/core/app_visibility.dart';
import 'package:anyware/core/background_service.dart';
import 'package:anyware/core/android_platform_service.dart';
import 'package:anyware/core/constants.dart';
import 'package:anyware/core/file_picker_helper.dart';
import 'package:anyware/core/logger.dart';
import 'package:anyware/core/responsive.dart';
import 'package:anyware/core/theme.dart';
import 'package:anyware/core/tv_detector.dart';
import 'package:anyware/features/settings/presentation/providers.dart';
import 'package:anyware/features/dashboard/presentation/dashboard_screen.dart';
import 'package:anyware/features/discovery/presentation/providers.dart';
import 'package:anyware/features/pairing/data/pairing_client.dart';
import 'package:anyware/features/pairing/domain/pairing_request.dart';
import 'package:anyware/features/pairing/presentation/pairing_prompt_dialog.dart';
import 'package:anyware/features/pairing/presentation/providers.dart';
import 'package:anyware/features/transfer/presentation/transfer_screen.dart';
import 'package:anyware/features/transfer/presentation/providers.dart';
import 'package:anyware/features/transfer/domain/transfer.dart';
import 'package:anyware/features/settings/presentation/settings_screen.dart';
import 'package:anyware/i18n/app_localizations.dart';
import 'package:anyware/widgets/desktop_content_shell.dart';
import 'package:anyware/widgets/desktop_status_bar.dart';
import 'package:anyware/features/clipboard/data/clipboard_service.dart';
import 'package:anyware/features/sync/presentation/sync_setup_dialog.dart';
import 'package:anyware/features/sync/data/sync_service.dart';
import 'package:anyware/features/sync/domain/sync_state.dart';
import 'package:anyware/features/server_sync/data/server_sync_service.dart';
import 'package:anyware/features/sharing/presentation/share_target_picker.dart';
import 'package:anyware/features/sharing/data/dropped_file_expander.dart';
import 'package:anyware/features/platform/tray_service.dart';
import 'package:anyware/features/platform/linux/linux_firewall_service.dart';
import 'package:anyware/features/settings/data/settings_repository.dart';
import 'package:anyware/widgets/app_states.dart';
import 'package:anyware/features/ileti/domain/ileti_message.dart';
import 'package:anyware/features/ileti/presentation/providers.dart';
import 'package:anyware/ui/devices_home.dart';
import 'package:anyware/ui/files_screen.dart';
import 'package:anyware/ui/sync_home.dart';
import 'package:anyware/ui/ui_kit.dart';
import 'package:anyware/ui/ui_strings.dart';

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

class _MainShellState extends ConsumerState<_MainShell>
    with WindowListener, WidgetsBindingObserver {
  int _selectedIndex = 0;
  bool _localeInitialized = false;

  /// Null follows the responsive default; once the user presses the toggle,
  /// their explicit choice wins even on a narrower desktop window.
  bool? _sidebarCollapsedOverride;
  bool _isGlobalDragging = false;
  bool _androidNetworkShouldRun = false;
  Timer? _visibilityPoll;

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
    // AnyWhere 2.0 (lib/ui): Cihazlar, Dosyalar, Eşitleme, Ayarlar — the
    // same four on phones (bottom bar) and desktops (rail).
    return const <Widget>[
      DevicesHome(),
      FilesScreen(),
      SyncHome(),
      SettingsScreen(),
    ];
  }

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    WidgetsBinding.instance.addObserver(this);
    PairingClient.waiting.addListener(_showOutgoingPairingCode);
    if (_useSidebar) _startVisibilityPoll();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initLocaleIfNeeded();
      if (Platform.isAndroid) {
        unawaited(_resumeAndroidNetwork());
      }
      if (Platform.isLinux) {
        unawaited(_checkLinuxFirewall());
      }
    });
  }

  /// Records whether the UI is on screen, so continuous animations can pause
  /// while it is not. Logged because the signals differ per platform and the
  /// cost of getting it wrong is a laptop running the GPU flat out in the tray.
  void _setUiVisible(bool visible, String source) {
    if (appUiVisible.value == visible) return;
    appUiVisible.value = visible;
    AppLogger('Window').info('UI visible = $visible (via $source)');
  }

  /// Polls the real window state on desktop.
  ///
  /// The minimize/restore/focus events do not fire reliably across window
  /// managers, and Flutter keeps producing frames for a minimized window, so
  /// the events alone can leave the flag stuck — either burning CPU while
  /// minimized, or freezing animations after the window comes back. A two
  /// second poll costs nothing measurable and makes the flag self-correcting;
  /// the events above still give an instant response wherever they do fire.
  void _startVisibilityPoll() {
    _visibilityPoll = Timer.periodic(const Duration(seconds: 2), (_) async {
      try {
        final visible = await windowManager.isVisible();
        final minimized = await windowManager.isMinimized();
        _setUiVisible(visible && !minimized, 'poll');
      } catch (_) {}
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        _setUiVisible(true, 'lifecycle.resumed');
        if (Platform.isAndroid) unawaited(_resumeAndroidNetwork());
        return;
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        _setUiVisible(false, 'lifecycle.$state');
        if (Platform.isAndroid) _pauseAndroidNetwork();
        return;
      case AppLifecycleState.inactive:
        // Desktop reports `inactive` when the window merely loses focus, so it
        // must not count as hidden there. On Android it precedes a real pause.
        if (Platform.isAndroid) _pauseAndroidNetwork();
        return;
    }
  }

  // Window events cover the desktop cases the lifecycle observer can miss —
  // notably hiding to the system tray, where the process keeps running and
  // Flutter keeps producing frames for a window nobody can see.

  @override
  void onWindowEvent(String eventName) {
    // Resize and move fire continuously while the user drags; logging those
    // would cost more than it tells us.
    const noisy = {'resize', 'resized', 'move', 'moved'};
    if (noisy.contains(eventName)) return;
    AppLogger('Window').info('Window event: $eventName');

    // WindowListener has no typed callback for show/hide, but window_manager
    // does emit them — and they cover every path that hides to or restores
    // from the tray, wherever show()/hide() is called from.
    switch (eventName) {
      case 'show':
        _setUiVisible(true, 'window.show');
      case 'hide':
        _setUiVisible(false, 'window.hide');
    }
  }

  @override
  void onWindowMinimize() => _setUiVisible(false, 'window.minimize');

  @override
  void onWindowRestore() => _setUiVisible(true, 'window.restore');

  @override
  void onWindowFocus() => _setUiVisible(true, 'window.focus');

  Future<void> _resumeAndroidNetwork() async {
    _androidNetworkShouldRun = true;
    unawaited(BackgroundTransferService.instance.stopPresence());
    await AndroidPlatformService.instance.acquireMulticastLock();
    try {
      final service = await ref.read(discoveryServiceProvider.future);
      service.setQuiet(false);
      if (!_androidNetworkShouldRun) {
        service.stop();
        await AndroidPlatformService.instance.releaseMulticastLock();
        return;
      }
      if (!service.isRunning) await service.start();
    } catch (_) {}
  }

  void _pauseAndroidNetwork() {
    _androidNetworkShouldRun = false;
    unawaited(AndroidPlatformService.instance.releaseMulticastLock());
    unawaited(_stayReachableOrStop());
  }

  /// In the background: with paired devices and Wi-Fi (and the setting on),
  /// the server and a quiet discovery stay up under a silent, lock-free
  /// foreground service, so a paired computer still sees this phone and can
  /// send to it. Otherwise discovery stops, as before.
  Future<void> _stayReachableOrStop() async {
    final discovery = ref.read(discoveryServiceProvider).valueOrNull;
    final settings = ref.read(settingsProvider);
    var onWifi = false;
    try {
      final links = await Connectivity().checkConnectivity();
      onWifi =
          links.contains(ConnectivityResult.wifi) ||
          links.contains(ConnectivityResult.ethernet);
    } catch (_) {}
    if (_androidNetworkShouldRun) return; // back on screen meanwhile
    final reachable =
        settings.stayReachable &&
        onWifi &&
        ref.read(trustStoreProvider).devices.isNotEmpty &&
        discovery != null;
    if (!reachable) {
      discovery?.stop();
      return;
    }
    discovery.setQuiet(true);
    if (!discovery.isRunning) await discovery.start();
    final locale = settings.locale;
    await BackgroundTransferService.instance.startPresence(
      title: AppLocalizations.get('presenceTitle', locale),
      text: AppLocalizations.get('presenceText', locale),
    );
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
      // window_manager emits no event for hide, so mark it here.
      _setUiVisible(false, 'tray.hide');
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
    _visibilityPoll?.cancel();
    PairingClient.waiting.removeListener(_showOutgoingPairingCode);
    windowManager.removeListener(this);
    WidgetsBinding.instance.removeObserver(this);
    if (Platform.isAndroid) {
      _pauseAndroidNetwork();
      unawaited(BackgroundTransferService.instance.shutdown());
    }
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
    _selectIndex(1);
  }

  void _navigateToClipboard() {
    if (_isTV) return;
    ref.read(filesFilterProvider.notifier).state = 4;
    _selectIndex(1);
  }

  void _selectIndex(int index) {
    if (_selectedIndex != index) {
      setState(() => _selectedIndex = index);
    }
    if (!_isTV && index == 1 && ref.read(filesFilterProvider) == 4) {
      ref.read(clipboardUnreadCountProvider.notifier).state = 0;
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

  /// While this device waits for another to accept its pairing over TLS:
  /// the code both screens show, to compare before allowing there.
  void _showOutgoingPairingCode() {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger.hideCurrentSnackBar();
    final waiting = PairingClient.waiting.value;
    if (waiting == null) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          AppLocalizations.format(
            'pairingCodeWaiting',
            ref.read(settingsProvider).locale,
            {'code': waiting.code},
          ),
        ),
        duration: const Duration(seconds: 75),
      ),
    );
  }

  PendingPairingPrompt? _shownPairingPrompt;

  /// Shows the pairing prompts one after another.
  void _showNextPairingPrompt(
    List<PendingPairingPrompt> prompts,
    String locale,
  ) {
    if (_shownPairingPrompt != null || prompts.isEmpty || !mounted) return;
    final prompt = prompts.first;
    _shownPairingPrompt = prompt;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => PairingPromptDialog(prompt: prompt, locale: locale),
    ).whenComplete(() {
      _shownPairingPrompt = null;
      // Closed without an answer (e.g. back key) counts as "reject".
      ref
          .read(pairingPromptProvider.notifier)
          .resolve(prompt, PairingDecision.reject);
      if (mounted) {
        _showNextPairingPrompt(ref.read(pairingPromptProvider), locale);
      }
    });
  }

  PendingEsitlemePrompt? _shownEsitlemePrompt;

  void _showNextEsitlemePrompt(
    List<PendingEsitlemePrompt> prompts,
    String locale,
  ) {
    if (_shownEsitlemePrompt != null || prompts.isEmpty || !mounted) return;
    final prompt = prompts.first;
    _shownEsitlemePrompt = prompt;
    final notifier = ref.read(esitlemePromptProvider.notifier);
    showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(AppLocalizations.get('esitlemeAskTitle', locale)),
        content: Text(
          AppLocalizations.format('esitlemeAskBody', locale, {
            'name': prompt.device.name,
          }),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(AppLocalizations.get('reject', locale)),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(AppLocalizations.get('esitlemeAllow', locale)),
          ),
        ],
      ),
    ).then((answer) {
      _shownEsitlemePrompt = null;
      // dismissed without an answer: not kept, asked again next time
      notifier.resolve(prompt, answer);
      if (mounted) {
        _showNextEsitlemePrompt(ref.read(esitlemePromptProvider), locale);
      }
    });
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

    ref.listen<ClipboardEntry?>(clipboardReceivedEventProvider, (prev, next) {
      if (next == null || identical(prev, next)) return;
      if (_selectedIndex == 1 && ref.read(filesFilterProvider) == 4 && !_isTV) {
        ref.read(clipboardUnreadCountProvider.notifier).state = 0;
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final message = AppLocalizations.get(
          'clipboardReceivedFrom',
          locale,
        ).replaceAll('{sender}', next.senderName);
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: Text(message),
              action: _isTV
                  ? null
                  : SnackBarAction(
                      label: AppLocalizations.get('openClipboard', locale),
                      onPressed: _navigateToClipboard,
                    ),
            ),
          );
      });
    });

    ref.listen<int>(clipboardOpenRequestProvider, (prev, next) {
      if (next > (prev ?? 0)) _navigateToClipboard();
    });

    // Auto-switch to Transfer screen when a new incoming transfer arrives.
    ref.listen<List<Transfer>>(activeTransfersProvider, (prev, next) {
      final prevIds = prev?.map((t) => t.id).toSet() ?? {};
      final hasNewTransfer = next.any((t) => !prevIds.contains(t.id));
      if (hasNewTransfer && next.any((t) => t.isActive)) {
        _navigateToTransfers();
      }
    });

    // One-time pairing prompt when an unknown device contacts us.
    ref.listen<List<PendingPairingPrompt>>(pairingPromptProvider, (_, next) {
      _showNextPairingPrompt(next, locale);
    });

    // A paired device asks to sync folders: asked once per device.
    ref.listen<List<PendingEsitlemePrompt>>(esitlemePromptProvider, (_, next) {
      _showNextEsitlemePrompt(next, locale);
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
                _selectIndex(intent.index);
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
    // The Dosyalar badge: what is moving now and unread clipboard entries.
    final transfers = ref.watch(activeTransfersProvider);
    final activeTransferCount = transfers.where((t) => t.isActive).length;
    final unreadClipboardCount = ref.watch(clipboardUnreadCountProvider);

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
                _Rail(
                  selectedIndex: _selectedIndex,
                  onSelected: _selectIndex,
                  destinations: _destinations(
                    locale,
                    activeTransferCount + unreadClipboardCount,
                  ),
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
                  _selectIndex(index);
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

    final transfers = ref.watch(activeTransfersProvider);
    final activeTransfers = transfers.where((t) => t.isActive).length;
    final unreadClipboard = ref.watch(clipboardUnreadCountProvider);
    final filesBadge = activeTransfers + unreadClipboard;
    final ui = Ui.of(context);

    return Scaffold(
      backgroundColor: ui.bg,
      body: _AnimatedIndexedStack(index: _selectedIndex, children: _screens),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedIndex,
        onDestinationSelected: _selectIndex,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        height: 72,
        backgroundColor: ui.surface,
        indicatorColor: ui.accentSoft,
        destinations: [
          for (final d in _destinations(locale, filesBadge))
            NavigationDestination(icon: d.icon, label: d.label),
        ],
      ),
    );
  }

  List<({Widget icon, String label})> _destinations(String locale, int filesBadge) {
    Widget badged(IconData icon, int n) =>
        n > 0 ? Badge(label: Text('$n'), child: Icon(icon)) : Icon(icon);
    final unreadChats = ref
        .watch(iletiProvider)
        .values
        .fold<int>(0, (n, list) => n + list.where((m) => m.status == IletiStatus.unread).length);
    return [
      (icon: badged(Icons.chat_bubble_outline_rounded, unreadChats), label: S.get('navDevices', locale)),
      (icon: badged(Icons.swap_vert_rounded, filesBadge), label: S.get('navFiles', locale)),
      (icon: const Icon(Icons.sync_rounded), label: S.get('navSync', locale)),
      (icon: const Icon(Icons.tune_rounded), label: S.get('navSettings', locale)),
    ];
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


/// The desktop rail of AnyWhere 2.0: the app mark, then the four sections.
class _Rail extends StatelessWidget {
  const _Rail({
    required this.selectedIndex,
    required this.onSelected,
    required this.destinations,
  });

  final int selectedIndex;
  final ValueChanged<int> onSelected;
  final List<({Widget icon, String label})> destinations;

  @override
  Widget build(BuildContext context) {
    final ui = Ui.of(context);
    return Container(
      width: 84,
      decoration: BoxDecoration(
        color: ui.dark ? const Color(0xFF0C0A12) : const Color(0xFFF1EFF7),
        border: Border(right: BorderSide(color: ui.border)),
      ),
      child: Column(
        children: [
          const SizedBox(height: 16),
          // AnyWhere's own logo (assets/icons/logo.png), as the old sidebar had it
          const AppLogo(size: 40),
          const SizedBox(height: 20),
          for (var i = 0; i < destinations.length; i++)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Tooltip(
                message: destinations[i].label,
                child: Material(
                  color: i == selectedIndex ? ui.accentSoft : Colors.transparent,
                  borderRadius: BorderRadius.circular(14),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(14),
                    onTap: () => onSelected(i),
                    child: SizedBox(
                      width: 64,
                      height: 56,
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          IconTheme(
                            data: IconThemeData(
                              size: 20,
                              color: i == selectedIndex ? ui.text : ui.muted,
                            ),
                            child: destinations[i].icon,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            destinations[i].label,
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: i == selectedIndex ? FontWeight.w600 : FontWeight.w500,
                              color: i == selectedIndex ? ui.text : ui.muted,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
