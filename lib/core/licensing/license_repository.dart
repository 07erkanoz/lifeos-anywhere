import 'package:anyware/core/licensing/license_models.dart';

/// License repository — stub, app is free.
class LicenseRepository {
  bool get isConfigured => false;

  Future<LicenseInfo> activateDevice({
    required String activationCode,
    required String deviceUuid,
    required String deviceName,
    required String platform,
    required String appVersion,
  }) async => LicenseInfo.free;

  Future<LicenseInfo> getLicense(String activationCode) async => LicenseInfo.free;

  Future<void> deactivateDevice({
    required String activationCode,
    required String deviceUuid,
  }) async {}

  Future<void> heartbeat({
    required String activationCode,
    required String deviceUuid,
  }) async {}

  void dispose() {}
}

class LicenseException implements Exception {
  final String code;
  LicenseException(this.code);

  @override
  String toString() => 'LicenseException: $code';
}
