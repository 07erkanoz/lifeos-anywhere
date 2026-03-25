import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:purchases_flutter/purchases_flutter.dart' hide LogLevel;

import 'package:anyware/core/cloud_credentials.dart';
import 'package:anyware/core/logger.dart';

final _log = AppLogger('PurchaseService');

/// Riverpod provider for RevenueCat purchase operations.
final purchaseServiceProvider = Provider<PurchaseService>((ref) {
  return PurchaseService();
});

/// Wraps RevenueCat SDK for subscription purchases and restoration.
///
/// RevenueCat handles receipt validation, subscription management, and
/// webhook delivery to our Supabase Edge Functions automatically.
class PurchaseService {
  bool _initialized = false;

  /// Initialize RevenueCat SDK. Call once at app startup.
  Future<void> init() async {
    if (_initialized) return;
    if (!CloudCredentials.hasRevenueCat) {
      _log.warning('RevenueCat API key not configured — skipping init');
      return;
    }

    // RevenueCat only supports mobile platforms for now.
    // Desktop users will use activation codes from mobile purchases.
    if (!Platform.isAndroid && !Platform.isIOS) {
      _log.info('RevenueCat skipped on desktop — use activation codes');
      return;
    }

    // RevenueCat SDK blocks release builds with test keys (shows a fatal
    // "Wrong API Key" dialog). Skip init when a test key is detected in
    // release mode — activation codes still work without RevenueCat.
    final key = CloudCredentials.revenueCatApiKey;
    const isRelease = bool.fromEnvironment('dart.vm.product');
    if (isRelease && key.startsWith('test_')) {
      _log.warning(
        'RevenueCat test key detected in release build — skipping init. '
        'Use a production key (goog_xxx) for store purchases.',
      );
      return;
    }

    try {
      final config = PurchasesConfiguration(key);
      await Purchases.configure(config);
      _initialized = true;
      _log.info('RevenueCat initialized');
    } catch (e) {
      _log.error('RevenueCat init failed: $e', error: e);
    }
  }

  /// Whether RevenueCat is available on this platform.
  bool get isAvailable =>
      _initialized && (Platform.isAndroid || Platform.isIOS);

  /// Get available subscription packages/offerings.
  Future<Offerings?> getOfferings() async {
    if (!isAvailable) return null;
    try {
      return await Purchases.getOfferings();
    } catch (e) {
      _log.error('Failed to get offerings: $e', error: e);
      return null;
    }
  }

  /// Purchase a package from RevenueCat.
  ///
  /// On success, RevenueCat webhook will create/update the Supabase license.
  /// Returns the RevenueCat app user ID for the purchase.
  Future<String?> purchase(Package package) async {
    if (!isAvailable) return null;
    try {
      final result = await Purchases.purchase(
        PurchaseParams.package(package),
      );
      final info = result.customerInfo;

      if (info.entitlements.active.containsKey('pro')) {
        _log.info('Purchase successful — Pro entitlement active');
        return info.originalAppUserId;
      }
      return null;
    } catch (e) {
      _log.error('Purchase failed: $e', error: e);
      return null;
    }
  }

  /// Restore purchases (e.g., reinstalled app on same store account).
  ///
  /// Returns the RevenueCat app user ID if an active Pro entitlement is found.
  Future<String?> restorePurchases() async {
    if (!isAvailable) return null;
    try {
      final info = await Purchases.restorePurchases();
      if (info.entitlements.active.containsKey('pro')) {
        _log.info('Restore successful — Pro entitlement found');
        return info.originalAppUserId;
      }
      _log.info('Restore completed — no active Pro entitlement');
      return null;
    } catch (e) {
      _log.error('Restore failed: $e', error: e);
      return null;
    }
  }

  /// Get the current RevenueCat customer info.
  Future<CustomerInfo?> getCustomerInfo() async {
    if (!isAvailable) return null;
    try {
      return await Purchases.getCustomerInfo();
    } catch (e) {
      _log.error('Failed to get customer info: $e', error: e);
      return null;
    }
  }
}
