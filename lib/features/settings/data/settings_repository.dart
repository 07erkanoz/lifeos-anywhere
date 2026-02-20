import 'dart:convert';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:anyware/features/settings/domain/settings.dart';

const String _settingsKey = 'app_settings';

class SettingsRepository {
  final SharedPreferences _prefs;

  SettingsRepository(this._prefs);

  /// Loads the saved settings from SharedPreferences.
  /// Returns default settings if nothing is saved yet.
  Future<AppSettings> load() async {
    final jsonString = _prefs.getString(_settingsKey);

    AppSettings settings;
    if (jsonString != null) {
      try {
        final json = jsonDecode(jsonString) as Map<String, dynamic>;
        settings = AppSettings.fromJson(json);
      } catch (_) {
        settings = AppSettings.defaults();
      }
    } else {
      settings = AppSettings.defaults();
    }

    // Populate device name if empty.
    if (settings.deviceName.isEmpty) {
      final deviceName = await getDeviceName();
      settings = settings.copyWith(deviceName: deviceName);
    }

    // Populate download path if empty, or re-evaluate if not writable.
    if (settings.downloadPath.isEmpty) {
      final downloadPath = await _getDefaultDownloadPath();
      settings = settings.copyWith(downloadPath: downloadPath);
    } else if (Platform.isAndroid) {
      // Verify the saved download path is still writable.
      // On Android TV or after permission changes, the previously saved path
      // (e.g. /storage/emulated/0/Download) may no longer be writable.
      final writable = await _isPathWritable(settings.downloadPath);
      if (!writable) {
        final downloadPath = await _getDefaultDownloadPath();
        if (downloadPath != settings.downloadPath && downloadPath.isNotEmpty) {
          settings = settings.copyWith(downloadPath: downloadPath);
          await save(settings);
        }
      }
    }

    return settings;
  }

  /// Persists the given settings to SharedPreferences.
  Future<void> save(AppSettings settings) async {
    final jsonString = jsonEncode(settings.toJson());
    await _prefs.setString(_settingsKey, jsonString);
  }

  /// Returns the saved device name, or generates a sensible default
  /// based on the current platform using device_info_plus.
  Future<String> getDeviceName() async {
    // Check if a name is already saved.
    final jsonString = _prefs.getString(_settingsKey);
    if (jsonString != null) {
      try {
        final json = jsonDecode(jsonString) as Map<String, dynamic>;
        final name = json['deviceName'] as String?;
        if (name != null && name.isNotEmpty) {
          return name;
        }
      } catch (_) {
        // Fall through to generate default.
      }
    }

    return _generateDefaultDeviceName();
  }

  /// Generates a default device name based on platform info.
  Future<String> _generateDefaultDeviceName() async {
    final deviceInfo = DeviceInfoPlugin();

    try {
      if (Platform.isWindows) {
        final windowsInfo = await deviceInfo.windowsInfo;
        final computerName = windowsInfo.computerName;
        return computerName.isNotEmpty ? computerName : 'Windows PC';
      } else if (Platform.isAndroid) {
        final androidInfo = await deviceInfo.androidInfo;
        final brand = androidInfo.brand;
        final model = androidInfo.model;
        if (brand.isNotEmpty && model.isNotEmpty) {
          final capitalizedBrand = brand[0].toUpperCase() + brand.substring(1);
          return '$capitalizedBrand $model';
        }
        return 'Android Device';
      } else if (Platform.isIOS) {
        final iosInfo = await deviceInfo.iosInfo;
        final name = iosInfo.name;
        return name.isNotEmpty ? name : 'iPhone';
      } else if (Platform.isLinux) {
        final linuxInfo = await deviceInfo.linuxInfo;
        final prettyName = linuxInfo.prettyName;
        return prettyName.isNotEmpty ? prettyName : 'Linux PC';
      } else if (Platform.isMacOS) {
        final macInfo = await deviceInfo.macOsInfo;
        final computerName = macInfo.computerName;
        return computerName.isNotEmpty ? computerName : 'Mac';
      }
    } catch (_) {
      // Fall through to generic default.
    }

    return 'LifeOS Device';
  }

  /// Checks whether the given path is writable by creating a temp file.
  Future<bool> _isPathWritable(String path) async {
    try {
      final dir = Directory(path);
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      final testFile = File('$path/.lifeos_write_test');
      await testFile.writeAsString('test');
      await testFile.delete();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Gets the default download path for the current platform.
  Future<String> _getDefaultDownloadPath() async {
    try {
      if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
        final downloadsDir = await getDownloadsDirectory();
        if (downloadsDir != null) {
          return downloadsDir.path;
        }
      }

      if (Platform.isAndroid) {
        // Prefer the public Download folder so received files are visible
        // in file managers and accessible by other apps.
        // Only use it if we can actually write to it (MANAGE_EXTERNAL_STORAGE).
        final publicDownload = Directory('/storage/emulated/0/Download');
        try {
          if (!await publicDownload.exists()) {
            await publicDownload.create(recursive: true);
          }
          // Test write access by creating and deleting a temp file.
          final testFile = File('${publicDownload.path}/.lifeos_test');
          await testFile.writeAsString('test');
          await testFile.delete();
          return publicDownload.path;
        } catch (_) {
          // No write access — fall through to app-private directory.
        }
        // Fallback: app-specific external directory (always writable).
        final externalDir = await getExternalStorageDirectory();
        if (externalDir != null) {
          return externalDir.path;
        }
      }

      final appDir = await getApplicationDocumentsDirectory();
      return appDir.path;
    } catch (_) {
      return '';
    }
  }
}

/// Riverpod provider for SharedPreferences instance.
/// Must be overridden in main() with the actual SharedPreferences instance.
final sharedPreferencesProvider = Provider<SharedPreferences>((ref) {
  throw UnimplementedError(
    'sharedPreferencesProvider must be overridden with a valid SharedPreferences instance.',
  );
});

/// Riverpod provider for SettingsRepository.
final settingsRepositoryProvider = Provider<SettingsRepository>((ref) {
  final prefs = ref.watch(sharedPreferencesProvider);
  return SettingsRepository(prefs);
});
