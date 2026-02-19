import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import 'package:anyware/core/logger.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:anyware/core/constants.dart';
import 'package:anyware/features/discovery/domain/device.dart';

/// Represents a clipboard entry with metadata.
class ClipboardEntry {
  final String text;
  final String? imagePath;
  final String senderName;
  final String senderDeviceId;
  final DateTime timestamp;
  final ClipboardContentType type;

  const ClipboardEntry({
    this.text = '',
    this.imagePath,
    required this.senderName,
    required this.senderDeviceId,
    required this.timestamp,
    this.type = ClipboardContentType.text,
  });

  Map<String, dynamic> toJson() => {
    'text': text,
    'imagePath': imagePath,
    'senderName': senderName,
    'senderDeviceId': senderDeviceId,
    'timestamp': timestamp.toIso8601String(),
    'type': type.name,
  };

  factory ClipboardEntry.fromJson(Map<String, dynamic> json) => ClipboardEntry(
    text: json['text'] as String? ?? '',
    imagePath: json['imagePath'] as String?,
    senderName: json['senderName'] as String? ?? 'Unknown',
    senderDeviceId: json['senderDeviceId'] as String? ?? '',
    timestamp: DateTime.tryParse(json['timestamp'] as String? ?? '') ?? DateTime.now(),
    type: ClipboardContentType.values.firstWhere(
      (e) => e.name == (json['type'] as String? ?? 'text'),
      orElse: () => ClipboardContentType.text,
    ),
  );
}

enum ClipboardContentType { text, image }

/// Provider for the clipboard service.
final clipboardServiceProvider = Provider((ref) => ClipboardService());

/// Provider for clipboard history.
final clipboardHistoryProvider =
    StateNotifierProvider<ClipboardHistoryNotifier, List<ClipboardEntry>>(
  (ref) => ClipboardHistoryNotifier(),
);

/// Manages clipboard history (last 20 entries).
class ClipboardHistoryNotifier extends StateNotifier<List<ClipboardEntry>> {
  ClipboardHistoryNotifier() : super([]);

  static const int _maxHistory = 20;

  void addEntry(ClipboardEntry entry) {
    // Avoid duplicates (same text within last 2 seconds).
    if (state.isNotEmpty) {
      final last = state.first;
      if (last.text == entry.text &&
          entry.timestamp.difference(last.timestamp).inSeconds < 2) {
        return;
      }
    }

    state = [entry, ...state].take(_maxHistory).toList();
  }

  void clear() {
    state = [];
  }

  void removeAt(int index) {
    if (index >= 0 && index < state.length) {
      state = [...state]..removeAt(index);
    }
  }
}

/// Provider for auto clipboard sync toggle.
final clipboardAutoSyncProvider = StateProvider<bool>((ref) => false);

/// Provider for the paired device for clipboard sync.
final clipboardSyncTargetProvider = StateProvider<Device?>((ref) => null);

class ClipboardService {
  static final _log = AppLogger('Clipboard');

  Timer? _autoSyncTimer;
  String? _lastClipboardText;

  /// Sends the given [text] to the [target] device's clipboard.
  Future<void> sendClipboard(
    Device target,
    String text, {
    required String senderName,
    required String senderDeviceId,
  }) async {
    final url = Uri.parse(
      'http://${target.ip}:${AppConstants.defaultPort}/api/clipboard',
    );

    try {
      final response = await http.post(
        url,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'text': text,
          'sender': senderName,
          'senderDeviceId': senderDeviceId,
          'type': 'text',
          'timestamp': DateTime.now().toIso8601String(),
        }),
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode != 200) {
        throw Exception('Failed to send clipboard: ${response.statusCode}');
      }
    } catch (e) {
      throw Exception('Clipboard transfer error: $e');
    }
  }

  /// Sends an image file to the target device's clipboard.
  Future<void> sendImageClipboard(
    Device target,
    String imagePath, {
    required String senderName,
    required String senderDeviceId,
  }) async {
    final url = Uri.parse(
      'http://${target.ip}:${AppConstants.defaultPort}/api/clipboard',
    );

    final file = File(imagePath);
    if (!file.existsSync()) return;

    final bytes = await file.readAsBytes();
    final base64Image = base64Encode(bytes);

    try {
      final response = await http.post(
        url,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'text': '',
          'imageBase64': base64Image,
          'sender': senderName,
          'senderDeviceId': senderDeviceId,
          'type': 'image',
          'timestamp': DateTime.now().toIso8601String(),
        }),
      ).timeout(const Duration(seconds: 30));

      if (response.statusCode != 200) {
        throw Exception('Failed to send image clipboard: ${response.statusCode}');
      }
    } catch (e) {
      throw Exception('Image clipboard transfer error: $e');
    }
  }

  /// Copies text to the local system clipboard.
  Future<void> copyToLocal(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
  }

  /// Starts auto-sync: periodically checks the local clipboard and sends
  /// changes to the target device.
  void startAutoSync(
    Device target, {
    required String senderName,
    required String senderDeviceId,
    Duration interval = const Duration(seconds: 2),
    void Function(ClipboardEntry)? onSynced,
  }) {
    stopAutoSync();
    _lastClipboardText = null;

    _autoSyncTimer = Timer.periodic(interval, (_) async {
      try {
        final data = await Clipboard.getData(Clipboard.kTextPlain);
        final currentText = data?.text;

        if (currentText != null &&
            currentText.isNotEmpty &&
            currentText != _lastClipboardText) {
          _lastClipboardText = currentText;

          await sendClipboard(
            target,
            currentText,
            senderName: senderName,
            senderDeviceId: senderDeviceId,
          );

          final entry = ClipboardEntry(
            text: currentText,
            senderName: senderName,
            senderDeviceId: senderDeviceId,
            timestamp: DateTime.now(),
          );
          onSynced?.call(entry);

          _log.debug('Auto-synced clipboard to ${target.name}');
        }
      } catch (e) {
        _log.warning('Auto-sync error: $e');
      }
    });
  }

  /// Stops auto-sync.
  void stopAutoSync() {
    _autoSyncTimer?.cancel();
    _autoSyncTimer = null;
  }

  /// Whether auto-sync is currently running.
  bool get isAutoSyncing => _autoSyncTimer != null && _autoSyncTimer!.isActive;

  void dispose() {
    stopAutoSync();
  }
}
