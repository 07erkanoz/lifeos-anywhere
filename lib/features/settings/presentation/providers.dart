import 'dart:io';

import 'package:anyware/features/platform/windows/startup_service.dart';
import 'package:anyware/features/platform/windows/context_menu_service.dart';
import 'package:anyware/features/settings/data/settings_repository.dart';
import 'package:anyware/features/settings/domain/settings.dart';
import 'package:anyware/core/logger.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Provides the current [AppSettings] and exposes mutation methods.
///
/// Settings are loaded from the [SettingsRepository] on initialization and
/// persisted back after every change.
final settingsProvider =
    StateNotifierProvider<SettingsNotifier, AppSettings>((ref) {
  final repo = ref.watch(settingsRepositoryProvider);
  return SettingsNotifier(repo);
});

/// [StateNotifier] that wraps [AppSettings] with convenient setter methods.
///
/// Every mutation immediately persists the new state via [SettingsRepository].
/// Windows platform toggles (startup, tray, explorer menu) now also invoke
/// the corresponding platform service so the changes actually take effect.
class SettingsNotifier extends StateNotifier<AppSettings> {
  SettingsNotifier(this._repo) : super(AppSettings.defaults()) {
    _loadInitial();
  }

  static final _log = AppLogger('Settings');

  final SettingsRepository _repo;

  // Windows platform services — lazy-initialized on first toggle.
  WindowsStartupService? _startupService;
  WindowsContextMenuService? _contextMenuService;

  WindowsStartupService get _startup {
    if (_startupService == null) {
      _startupService = WindowsStartupService();
      _startupService!.setup();
    }
    return _startupService!;
  }

  WindowsContextMenuService get _contextMenu {
    _contextMenuService ??= WindowsContextMenuService();
    return _contextMenuService!;
  }

  /// Loads settings from persistent storage. Called once during construction.
  Future<void> _loadInitial() async {
    try {
      final loaded = await _repo.load();
      if (mounted) {
        state = loaded;
      }
    } catch (_) {
      // Keep the default settings on failure.
    }
  }

  // --------------------------------------------------------------------------
  // Mutation methods
  // --------------------------------------------------------------------------

  /// Updates the user-visible device name.
  Future<void> updateDeviceName(String name) async {
    state = state.copyWith(deviceName: name);
    await _persist();
  }

  /// Updates the directory where received files are saved.
  Future<void> updateDownloadPath(String path) async {
    state = state.copyWith(downloadPath: path);
    await _persist();
  }

  /// Updates the app theme. Expected values: `"system"`, `"light"`, `"dark"`.
  Future<void> updateTheme(String theme) async {
    state = state.copyWith(theme: theme);
    await _persist();
  }

  /// Updates the locale / language code (e.g. `"en"`, `"tr"`).
  Future<void> updateLocale(String locale) async {
    state = state.copyWith(locale: locale);
    await _persist();
  }

  /// Toggles automatic acceptance of incoming file transfers.
  Future<void> toggleAutoAccept() async {
    state = state.copyWith(autoAcceptFiles: !state.autoAcceptFiles);
    await _persist();
  }

  /// Toggles overwriting existing files with the same name.
  Future<void> toggleOverwriteFiles() async {
    state = state.copyWith(overwriteFiles: !state.overwriteFiles);
    await _persist();
  }

  /// Toggles whether the app starts automatically at system login.
  ///
  /// Now actually calls [WindowsStartupService.enable] / [disable] so the
  /// registry entry is created/removed — previously only persisted the flag.
  Future<void> toggleLaunchAtStartup() async {
    final newValue = !state.launchAtStartup;
    state = state.copyWith(launchAtStartup: newValue);
    await _persist();

    if (Platform.isWindows) {
      try {
        if (newValue) {
          await _startup.enable();
        } else {
          await _startup.disable();
        }
      } catch (e) {
        _log.error('Startup toggle failed: $e', error: e);
      }
    }
  }

  /// Toggles whether the app minimizes to the system tray instead of closing.
  Future<void> toggleMinimizeToTray() async {
    final newValue = !state.minimizeToTray;
    state = state.copyWith(minimizeToTray: newValue);
    await _persist();

    // Tray init/dispose is handled in WindowsService.init, but we
    // persist the preference so it takes effect on next launch.
  }

  /// Toggles the "Send with AnyWhere" option in the OS file explorer context
  /// menu (Windows shell extension).
  Future<void> toggleExplorerMenu() async {
    final newValue = !state.showInExplorerMenu;
    state = state.copyWith(showInExplorerMenu: newValue);
    await _persist();

    if (Platform.isWindows) {
      try {
        if (newValue) {
          _contextMenu.register();
        } else {
          _contextMenu.unregister();
        }
      } catch (e) {
        _log.error('Explorer menu toggle failed: $e', error: e);
      }
    }
  }

  // --------------------------------------------------------------------------
  // Private helpers
  // --------------------------------------------------------------------------

  /// Persists the current state to the repository.
  Future<void> _persist() async {
    try {
      await _repo.save(state);
    } catch (_) {
      // Persistence failure is non-fatal; the in-memory state is still valid.
    }
  }
}
