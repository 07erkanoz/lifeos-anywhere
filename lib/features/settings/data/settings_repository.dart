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

    // Populate download path if empty.
    if (settings.downloadPath.isEmpty) {
      final downloadPath = await _getDefaultDownloadPath();
      settings = settings.copyWith(downloadPath: downloadPath);
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
        final publicDownload = Directory('/storage/emulated/0/Download');
        if (await publicDownload.exists()) {
          return publicDownload.path;
        }
        // Fallback: external storage root.
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
