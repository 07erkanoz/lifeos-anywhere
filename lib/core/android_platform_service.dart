import 'dart:io';

import 'package:flutter/services.dart';

import 'package:anyware/core/logger.dart';

final _log = AppLogger('AndroidPlatform');

/// Provides access to Android-specific platform features via MethodChannel.
///
/// - MulticastLock: keeps WiFi chipset listening for UDP multicast when screen off.
/// - Battery optimization: requests exemption from Doze mode.
class AndroidPlatformService {
  AndroidPlatformService._();
  static final AndroidPlatformService instance = AndroidPlatformService._();

  static const _channel = MethodChannel('com.lifeos.anyware/platform');

  /// Acquires the WiFi MulticastLock so UDP discovery works with screen off.
  Future<void> acquireMulticastLock() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('acquireMulticastLock');
      _log.info('MulticastLock acquired');
    } catch (e) {
      _log.warning('Failed to acquire MulticastLock: $e');
    }
  }

  /// Unbinds the process from a specific network, restoring default routing.
  ///
  /// Must be called after [connectToWifi] completes so that discovery
  /// broadcasts use the default network route instead of being pinned to
  /// the hotspot network.
  Future<void> unbindNetwork() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('unbindNetwork');
      _log.info('Process unbound from specific network');
    } catch (e) {
      _log.warning('Failed to unbind network: $e');
    }
  }

  /// Releases the WiFi MulticastLock.
  Future<void> releaseMulticastLock() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('releaseMulticastLock');
      _log.info('MulticastLock released');
    } catch (e) {
      _log.warning('Failed to release MulticastLock: $e');
    }
  }

  /// Checks if the app is exempt from battery optimization.
  Future<bool> isBatteryOptimizationExempt() async {
    if (!Platform.isAndroid) return true;
    try {
      final result =
          await _channel.invokeMethod<bool>('isBatteryOptimizationExempt');
      return result ?? false;
    } catch (e) {
      _log.warning('Failed to check battery optimization status: $e');
      return false;
    }
  }

  /// Requests battery optimization exemption from the user.
  ///
  /// Returns `true` if already exempt, `false` if the dialog was shown.
  Future<bool> requestBatteryOptimizationExemption() async {
    if (!Platform.isAndroid) return true;
    try {
      final result = await _channel
          .invokeMethod<bool>('requestBatteryOptimizationExemption');
      return result ?? false;
    } catch (e) {
      _log.warning('Failed to request battery optimization exemption: $e');
      return false;
    }
  }
}
