import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:anyware/core/licensing/license_models.dart';
import 'package:anyware/core/licensing/license_repository.dart';

// ── Providers ──

final licenseRepositoryProvider = Provider<LicenseRepository>((ref) {
  return LicenseRepository();
});

final licenseServiceProvider =
    StateNotifierProvider<LicenseService, LicenseInfo>((ref) {
  return LicenseService();
});

// ── Service (stub — always Pro) ──

class LicenseService extends StateNotifier<LicenseInfo> {
  LicenseService() : super(LicenseInfo.free);

  Future<void> activateWithCode(String code) async {}
  Future<void> refresh() async {}
  Future<void> removeDevice(String deviceUuid) async {}
  Future<void> clearLicense() async {}

  String get currentDeviceUuid => '';
}
