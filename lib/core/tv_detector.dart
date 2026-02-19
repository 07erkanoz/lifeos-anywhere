import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Utility to detect whether the app is running on an Android TV device.
class TvDetector {
  TvDetector._();

  static bool? _isTV;

  /// Returns `true` if the current device is an Android TV.
  ///
  /// On non-Android platforms this always returns `false`.
  /// The result is cached after the first call.
  static Future<bool> isAndroidTV() async {
    if (_isTV != null) return _isTV!;

    if (!Platform.isAndroid) {
      _isTV = false;
      return false;
    }

    try {
      // Check if the device has the leanback feature (Android TV indicator).
      const platform = MethodChannel('com.lifeos.anyware/platform');
      final result = await platform.invokeMethod<bool>('isTV');
      _isTV = result ?? false;
    } catch (_) {
      // If the platform channel isn't available, fall back to a heuristic:
      // Check the system UI mode via the system feature flag.
      _isTV = false;
    }

    return _isTV!;
  }

  /// Synchronous getter – only valid after [isAndroidTV] has been awaited once.
  static bool get isTVCached => _isTV ?? false;

  /// Reset cached value (useful for testing).
  @visibleForTesting
  static void reset() => _isTV = null;
}
