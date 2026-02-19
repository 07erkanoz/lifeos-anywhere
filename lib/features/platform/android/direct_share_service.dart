import 'dart:io';

import 'package:flutter/services.dart';

import 'package:anyware/core/logger.dart';
import 'package:anyware/features/discovery/domain/device.dart';

/// Manages Android Direct Share targets via platform channel.
///
/// Pushes the list of recently discovered devices to the native
/// ShortcutManager so they appear in the Android share sheet.
class DirectShareService {
  DirectShareService();

  static final _log = AppLogger('DirectShare');
  static const _channel = MethodChannel('com.lifeos.anyware/platform');

  /// Updates the Android share sheet with the given devices.
  ///
  /// No-op on non-Android platforms.
  Future<void> updateTargets(List<Device> devices) async {
    if (!Platform.isAndroid) return;

    try {
      final deviceMaps = devices.map((d) => {
        'id': d.id,
        'name': d.name,
        'ip': d.ip,
        'port': d.port,
        'platform': d.platform,
      }).toList();

      await _channel.invokeMethod('updateDirectShareTargets', {
        'devices': deviceMaps,
      });
    } catch (e) {
      _log.warning('Failed to update direct share targets', error: e);
    }
  }

  /// Clears all direct share targets.
  Future<void> clearTargets() async {
    if (!Platform.isAndroid) return;

    try {
      await _channel.invokeMethod('clearDirectShareTargets');
    } catch (e) {
      _log.warning('Failed to clear direct share targets', error: e);
    }
  }
}
