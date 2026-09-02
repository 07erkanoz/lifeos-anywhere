import 'dart:io';

import 'package:flutter/services.dart';

import 'package:anyware/core/logger.dart';
import 'package:anyware/features/discovery/domain/device.dart';

class DirectShareTargetInfo {
  const DirectShareTargetInfo({
    required this.id,
    required this.name,
    required this.ip,
  });

  final String id;
  final String name;
  final String ip;

  factory DirectShareTargetInfo.fromMap(Map<Object?, Object?> map) {
    return DirectShareTargetInfo(
      id: map['id'] as String? ?? '',
      name: map['name'] as String? ?? '',
      ip: map['ip'] as String? ?? '',
    );
  }
}

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

  /// Returns and clears the device explicitly selected in Android Direct Share.
  Future<DirectShareTargetInfo?> consumeSelectedTarget() async {
    if (!Platform.isAndroid) return null;

    try {
      final value = await _channel.invokeMethod<Map<Object?, Object?>>(
        'consumeDirectShareTarget',
      );
      if (value == null) return null;
      final target = DirectShareTargetInfo.fromMap(value);
      return target.id.isEmpty ? null : target;
    } catch (e) {
      _log.warning('Failed to read selected direct share target', error: e);
      return null;
    }
  }
}
