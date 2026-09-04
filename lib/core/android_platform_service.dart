import 'dart:io';

import 'package:flutter/services.dart';

import 'package:anyware/core/logger.dart';

final _log = AppLogger('AndroidPlatform');

/// Provides access to Android-specific platform features via MethodChannel.
///
/// - MulticastLock: keeps the Wi-Fi chipset listening for UDP multicast while
///   the app is visible.
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
}
