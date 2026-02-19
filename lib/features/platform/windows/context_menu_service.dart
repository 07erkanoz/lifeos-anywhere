import 'dart:io';

import 'package:anyware/core/logger.dart';
import 'package:win32_registry/win32_registry.dart';

/// Manages Windows Explorer right-click context menu integration.
///
/// Registers and unregisters shell context menu entries that allow users
/// to share files and directories directly from Windows Explorer via
/// the "LifeOS AnyWhere ile Gonder" menu item.
///
/// On Windows 11, the entry appears under "Show more options" (classic menu).
/// The registration uses HKEY_CURRENT_USER so no admin privileges are needed.
class WindowsContextMenuService {
  WindowsContextMenuService();

  static final _log = AppLogger('ContextMenu');

  /// Registry path for the file-level context menu entry.
  static const String _fileShellKey =
      r'Software\Classes\*\shell\LifeOSShare';

  /// Registry path for the directory-level context menu entry.
  static const String _directoryShellKey =
      r'Software\Classes\Directory\shell\LifeOSShare';

  /// Registry path for background (empty area) context menu entry.
  static const String _backgroundShellKey =
      r'Software\Classes\Directory\Background\shell\LifeOSShare';

  /// Registers the context menu entries in the Windows Registry.
  ///
  /// Creates entries for files (`*\shell`), directories (`Directory\shell`),
  /// and directory background (right-clicking empty area).
  ///
  /// Also verifies the command path is correct (updates if the exe moved).
  void register() {
    if (!Platform.isWindows) return;

    final exePath = Platform.resolvedExecutable;

    try {
      // Register context menu for files.
      _registerShellKey(
        keyPath: _fileShellKey,
        exePath: exePath,
      );

      // Register context menu for directories.
      _registerShellKey(
        keyPath: _directoryShellKey,
        exePath: exePath,
      );

      // Register context menu for directory background.
      _registerShellKey(
        keyPath: _backgroundShellKey,
        exePath: exePath,
        isBackground: true,
      );

      _log.info('Context menu registered successfully.');
    } catch (e) {
      _log.error('Failed to register context menu: $e', error: e);
    }
  }

  /// Unregisters the context menu entries from the Windows Registry.
  void unregister() {
    if (!Platform.isWindows) return;

    for (final keyPath in [_fileShellKey, _directoryShellKey, _backgroundShellKey]) {
      try {
        _deleteShellKey(keyPath);
      } catch (e) {
        _log.warning('Failed to unregister $keyPath: $e');
      }
    }
  }

  /// Checks whether the context menu entry is currently registered
  /// AND points to the correct executable path.
  bool isRegistered() {
    if (!Platform.isWindows) return false;

    try {
      final key = Registry.openPath(
        RegistryHive.currentUser,
        path: '$_fileShellKey\\command',
      );
      final value = key.getStringValue('');
      key.close();

      // Verify the registered command points to the current executable.
      final exePath = Platform.resolvedExecutable;
      return value?.contains(exePath) ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Re-registers if the exe path has changed (e.g. after an update/move).
  void ensureUpToDate() {
    if (!Platform.isWindows) return;

    try {
      final key = Registry.openPath(
        RegistryHive.currentUser,
        path: '$_fileShellKey\\command',
      );
      final value = key.getStringValue('');
      key.close();

      final exePath = Platform.resolvedExecutable;
      if (value == null || !value.contains(exePath)) {
        _log.info('Exe path changed, re-registering...');
        register();
      }
    } catch (_) {
      // Key doesn't exist, register fresh.
      register();
    }
  }

  /// Creates a shell registry key with the display name, icon, and command.
  ///
  /// Uses [RegistryKey.createKey] which creates the key if it doesn't exist
  /// or opens it if it already exists (unlike [Registry.openPath] which only
  /// opens existing keys).
  void _registerShellKey({
    required String keyPath,
    required String exePath,
    bool isBackground = false,
  }) {
    try {
      // Open HKCU root and create the full path using createKey (RegCreateKey).
      final hkcu = Registry.openPath(
        RegistryHive.currentUser,
        desiredAccessRights: AccessRights.allAccess,
      );
      final shellKey = hkcu.createKey(keyPath);

      // Set the display name (default value).
      shellKey.createValue(
        const RegistryValue.string('', 'LifeOS AnyWhere ile Gonder'),
      );

      // Set the icon to the executable path.
      shellKey.createValue(
        RegistryValue.string('Icon', '"$exePath",0'),
      );

      // Position the entry higher in the menu.
      shellKey.createValue(
        const RegistryValue.string('Position', 'Top'),
      );

      // Create the command subkey.
      final commandKey = shellKey.createKey('command');

      if (isBackground) {
        // For background context menu, use %V for the current directory.
        commandKey.createValue(
          RegistryValue.string('', '"$exePath" "--share" "%V"'),
        );
      } else {
        commandKey.createValue(
          RegistryValue.string('', '"$exePath" "--share" "%1"'),
        );
      }

      commandKey.close();
      shellKey.close();
      hkcu.close();
    } catch (e) {
      _log.error('Failed to register shell key $keyPath: $e', error: e);
    }
  }

  /// Deletes a shell registry key and its subkeys.
  void _deleteShellKey(String keyPath) {
    try {
      // First try to delete the command subkey.
      final key = Registry.openPath(
        RegistryHive.currentUser,
        path: keyPath,
        desiredAccessRights: AccessRights.allAccess,
      );
      try {
        key.deleteKey('command');
      } catch (_) {}
      key.close();
    } catch (_) {}

    // Now delete the parent key itself.
    try {
      final lastSeparator = keyPath.lastIndexOf(r'\');
      final parentPath = keyPath.substring(0, lastSeparator);
      final keyName = keyPath.substring(lastSeparator + 1);

      final parentKey = Registry.openPath(
        RegistryHive.currentUser,
        path: parentPath,
        desiredAccessRights: AccessRights.allAccess,
      );
      parentKey.deleteKey(keyName);
      parentKey.close();
    } catch (_) {}
  }
}
