import 'dart:convert';

import 'package:http/http.dart' as http;

import 'package:anyware/core/cloud_credentials.dart';
import 'package:anyware/core/logger.dart';
import 'package:anyware/core/licensing/license_models.dart';

final _log = AppLogger('LicenseRepo');

/// REST client that talks to the Supabase `licenses` and
/// `device_activations` tables (+ Edge Functions for activation).
class LicenseRepository {
  final http.Client _client;
  final String _baseUrl;
  final String _anonKey;

  LicenseRepository({http.Client? client})
      : _client = client ?? http.Client(),
        _baseUrl = CloudCredentials.supabaseUrl,
        _anonKey = CloudCredentials.supabaseAnonKey;

  Map<String, String> get _headers => {
        'apikey': _anonKey,
        'Authorization': 'Bearer $_anonKey',
        'Content-Type': 'application/json',
        'Prefer': 'return=representation',
      };

  bool get isConfigured => _baseUrl.isNotEmpty && _anonKey.isNotEmpty;

  // ── Activate device with an activation code ──

  /// Sends the activation code + device info to a Supabase Edge Function.
  /// Returns the full [LicenseInfo] on success.
  Future<LicenseInfo> activateDevice({
    required String activationCode,
    required String deviceUuid,
    required String deviceName,
    required String platform,
    required String appVersion,
  }) async {
    final uri =
        Uri.parse('$_baseUrl/functions/v1/activate-device');

    final response = await _client
        .post(
          uri,
          headers: _headers,
          body: jsonEncode({
            'activation_code': activationCode,
            'device_uuid': deviceUuid,
            'device_name': deviceName,
            'platform': platform,
            'app_version': appVersion,
          }),
        )
        .timeout(const Duration(seconds: 15));

    if (response.statusCode == 409) {
      throw LicenseException('deviceLimitReached');
    }
    if (response.statusCode == 404) {
      throw LicenseException('invalidCode');
    }
    if (response.statusCode != 200) {
      _log.error('activate-device failed: ${response.statusCode} ${response.body}');
      throw LicenseException('activationFailed');
    }

    final json = jsonDecode(response.body) as Map<String, dynamic>;
    return _parseLicenseInfo(json);
  }

  // ── Get license by activation code ──

  /// Fetches the license + device list for a given activation code.
  Future<LicenseInfo> getLicense(String activationCode) async {
    final uri =
        Uri.parse('$_baseUrl/functions/v1/get-license');

    final response = await _client
        .post(
          uri,
          headers: _headers,
          body: jsonEncode({'activation_code': activationCode}),
        )
        .timeout(const Duration(seconds: 10));

    if (response.statusCode == 404) {
      throw LicenseException('licenseNotFound');
    }
    if (response.statusCode != 200) {
      _log.error('get-license failed: ${response.statusCode}');
      throw LicenseException('fetchFailed');
    }

    final json = jsonDecode(response.body) as Map<String, dynamic>;
    return _parseLicenseInfo(json);
  }

  // ── Deactivate a device ──

  /// Removes a device from the license, freeing a slot.
  Future<void> deactivateDevice({
    required String activationCode,
    required String deviceUuid,
  }) async {
    final uri =
        Uri.parse('$_baseUrl/functions/v1/deactivate-device');

    final response = await _client
        .post(
          uri,
          headers: _headers,
          body: jsonEncode({
            'activation_code': activationCode,
            'device_uuid': deviceUuid,
          }),
        )
        .timeout(const Duration(seconds: 10));

    if (response.statusCode != 200) {
      _log.error('deactivate-device failed: ${response.statusCode}');
      throw LicenseException('deactivationFailed');
    }
  }

  // ── Heartbeat (update last_seen_at) ──

  /// Updates `last_seen_at` for the current device so it doesn't get
  /// auto-cleaned after 30 days of inactivity.
  Future<void> heartbeat({
    required String activationCode,
    required String deviceUuid,
  }) async {
    final funcUri =
        Uri.parse('$_baseUrl/functions/v1/device-heartbeat');

    try {
      await _client
          .post(
            funcUri,
            headers: _headers,
            body: jsonEncode({
              'activation_code': activationCode,
              'device_uuid': deviceUuid,
            }),
          )
          .timeout(const Duration(seconds: 10));
    } catch (e) {
      // Heartbeat failures are non-critical — just log.
      _log.warning('Heartbeat failed: $e');
    }
  }

  // ── Helpers ──

  LicenseInfo _parseLicenseInfo(Map<String, dynamic> json) {
    final license = License.fromJson(json['license'] as Map<String, dynamic>);
    final devicesJson = json['devices'] as List<dynamic>? ?? [];
    final devices = devicesJson
        .map((d) => DeviceActivation.fromJson(d as Map<String, dynamic>))
        .toList();

    return LicenseInfo(license: license, devices: devices);
  }

  void dispose() {
    _client.close();
  }
}

class LicenseException implements Exception {
  final String code;
  LicenseException(this.code);

  @override
  String toString() => 'LicenseException: $code';
}
