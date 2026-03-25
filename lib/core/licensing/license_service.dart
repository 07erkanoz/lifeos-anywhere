import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'package:anyware/core/constants.dart';
import 'package:anyware/core/logger.dart';
import 'package:anyware/core/licensing/license_models.dart';
import 'package:anyware/core/licensing/license_repository.dart';

final _log = AppLogger('LicenseService');

// ── Providers ──

final licenseRepositoryProvider = Provider<LicenseRepository>((ref) {
  final repo = LicenseRepository();
  ref.onDispose(repo.dispose);
  return repo;
});

final licenseServiceProvider =
    StateNotifierProvider<LicenseService, LicenseInfo>((ref) {
  final repo = ref.watch(licenseRepositoryProvider);
  return LicenseService(repo);
});

// ── Service ──

/// Manages the current device's license state.
///
/// On init, loads the cached license from secure storage, then refreshes
/// from Supabase in the background. Provides methods for code activation,
/// device management, and offline grace-period handling.
class LicenseService extends StateNotifier<LicenseInfo> {
  LicenseService(this._repo) : super(LicenseInfo.free) {
    _init();
  }

  final LicenseRepository _repo;
  final _storage = const FlutterSecureStorage();
  Timer? _heartbeatTimer;

  static const _cacheKey = 'license_cache';
  static const _lastVerifiedKey = 'license_last_verified';
  static const _offlineLockDays = 30;

  String _deviceUuid = '';
  String _deviceName = '';
  String _platform = '';

  // ── Initialisation ──

  Future<void> _init() async {
    await _loadDeviceInfo();
    await _loadCache();

    if (_repo.isConfigured && state.activationCode.isNotEmpty) {
      await refresh();
      _startHeartbeat();
    }
  }

  Future<void> _loadDeviceInfo() async {
    final info = DeviceInfoPlugin();
    if (Platform.isWindows) {
      final win = await info.windowsInfo;
      _deviceUuid = win.deviceId;
      _deviceName = win.computerName;
      _platform = 'windows';
    } else if (Platform.isAndroid) {
      final android = await info.androidInfo;
      _deviceUuid = android.id;
      _deviceName = android.model;
      _platform = 'android';
    } else if (Platform.isLinux) {
      final linux = await info.linuxInfo;
      _deviceUuid = linux.machineId ?? '';
      _deviceName = linux.prettyName;
      _platform = 'linux';
    } else if (Platform.isMacOS) {
      final mac = await info.macOsInfo;
      _deviceUuid = mac.systemGUID ?? '';
      _deviceName = mac.computerName;
      _platform = 'macos';
    } else if (Platform.isIOS) {
      final ios = await info.iosInfo;
      _deviceUuid = ios.identifierForVendor ?? '';
      _deviceName = ios.name;
      _platform = 'ios';
    }
  }

  // ── Cache ──

  Future<void> _loadCache() async {
    try {
      final cached = await _storage.read(key: _cacheKey);
      if (cached != null) {
        final json = jsonDecode(cached) as Map<String, dynamic>;
        final info = LicenseInfo(
          license: License.fromJson(json['license'] as Map<String, dynamic>),
          devices: (json['devices'] as List<dynamic>?)
                  ?.map(
                      (d) => DeviceActivation.fromJson(d as Map<String, dynamic>))
                  .toList() ??
              [],
          isOfflineCached: true,
        );

        // Check offline grace period
        final lastVerified = await _storage.read(key: _lastVerifiedKey);
        if (lastVerified != null) {
          final lastDate = DateTime.tryParse(lastVerified);
          if (lastDate != null) {
            final daysSince = DateTime.now().difference(lastDate).inDays;
            if (daysSince > _offlineLockDays) {
              // Too long offline — revert to free
              _log.warning('Offline for $daysSince days — locking Pro');
              state = LicenseInfo.free;
              return;
            }
          }
        }

        state = info;
        _log.info('Loaded cached license: ${info.plan.id}');
      }
    } catch (e) {
      _log.warning('Failed to load license cache: $e');
    }
  }

  Future<void> _saveCache(LicenseInfo info) async {
    try {
      final json = {
        'license': info.license.toJson(),
        'devices': info.devices.map((d) => {
              'id': d.id,
              'license_id': d.licenseId,
              'device_uuid': d.deviceUuid,
              'device_name': d.deviceName,
              'platform': d.platform,
              'app_version': d.appVersion,
              'last_seen_at': d.lastSeenAt.toIso8601String(),
              'created_at': d.createdAt.toIso8601String(),
            }).toList(),
      };
      await _storage.write(key: _cacheKey, value: jsonEncode(json));
      await _storage.write(
        key: _lastVerifiedKey,
        value: DateTime.now().toIso8601String(),
      );
    } catch (e) {
      _log.warning('Failed to save license cache: $e');
    }
  }

  // ── Public API ──

  /// Activate this device using a `LIFE-XXXX-XXXX` code.
  Future<void> activateWithCode(String code) async {
    final info = await _repo.activateDevice(
      activationCode: code.trim().toUpperCase(),
      deviceUuid: _deviceUuid,
      deviceName: _deviceName,
      platform: _platform,
      appVersion: AppConstants.appVersion,
    );
    state = info;
    await _saveCache(info);
    _startHeartbeat();
    _log.info('Activated with code: ${info.plan.id}');
  }

  /// Refresh license info from Supabase.
  Future<void> refresh() async {
    if (state.activationCode.isEmpty) return;

    try {
      final info = await _repo.getLicense(state.activationCode);
      if (mounted) {
        state = info;
        await _saveCache(info);
      }
    } catch (e) {
      _log.warning('License refresh failed (will use cache): $e');
    }
  }

  /// Remove a device from the license.
  Future<void> removeDevice(String deviceUuid) async {
    await _repo.deactivateDevice(
      activationCode: state.activationCode,
      deviceUuid: deviceUuid,
    );
    await refresh();
  }

  /// Clear local license data (log out of Pro).
  Future<void> clearLicense() async {
    _heartbeatTimer?.cancel();
    await _storage.delete(key: _cacheKey);
    await _storage.delete(key: _lastVerifiedKey);
    if (mounted) {
      state = LicenseInfo.free;
    }
  }

  /// The device UUID for this device.
  String get currentDeviceUuid => _deviceUuid;

  // ── Heartbeat ──

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(
      const Duration(hours: 6),
      (_) => _sendHeartbeat(),
    );
  }

  Future<void> _sendHeartbeat() async {
    if (state.activationCode.isEmpty) return;
    await _repo.heartbeat(
      activationCode: state.activationCode,
      deviceUuid: _deviceUuid,
    );
  }

  @override
  void dispose() {
    _heartbeatTimer?.cancel();
    super.dispose();
  }
}
