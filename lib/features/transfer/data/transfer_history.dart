import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:anyware/features/settings/data/settings_repository.dart';
import 'package:anyware/features/transfer/domain/transfer.dart';

/// A lightweight record of a completed or failed transfer for history.
class TransferRecord {
  final String fileName;
  final int fileSize;
  final String deviceName;
  final bool isSending;
  final bool succeeded;
  final String? error;
  final DateTime timestamp;

  const TransferRecord({
    required this.fileName,
    required this.fileSize,
    required this.deviceName,
    required this.isSending,
    required this.succeeded,
    this.error,
    required this.timestamp,
  });

  Map<String, dynamic> toJson() => {
    'fileName': fileName,
    'fileSize': fileSize,
    'deviceName': deviceName,
    'isSending': isSending,
    'succeeded': succeeded,
    'error': error,
    'timestamp': timestamp.toIso8601String(),
  };

  factory TransferRecord.fromJson(Map<String, dynamic> json) => TransferRecord(
    fileName: json['fileName'] as String? ?? '',
    fileSize: json['fileSize'] as int? ?? 0,
    deviceName: json['deviceName'] as String? ?? '',
    isSending: json['isSending'] as bool? ?? true,
    succeeded: json['succeeded'] as bool? ?? false,
    error: json['error'] as String?,
    timestamp: DateTime.tryParse(json['timestamp'] as String? ?? '') ?? DateTime.now(),
  );

  /// Creates a record from a finished [Transfer].
  factory TransferRecord.fromTransfer(Transfer transfer) => TransferRecord(
    fileName: transfer.fileName,
    fileSize: transfer.fileSize,
    deviceName: transfer.deviceName,
    isSending: transfer.isSending,
    succeeded: transfer.status == TransferStatus.completed,
    error: transfer.error,
    timestamp: DateTime.now(),
  );

  /// Formatted file size string.
  String get formattedSize {
    if (fileSize < 1024) return '$fileSize B';
    if (fileSize < 1024 * 1024) return '${(fileSize / 1024).toStringAsFixed(1)} KB';
    if (fileSize < 1024 * 1024 * 1024) {
      return '${(fileSize / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(fileSize / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
}

/// SharedPreferences key for persisted transfer history.
const _historyKey = 'transfer_history';

/// Maximum number of history records to keep.
const _maxHistorySize = 100;

/// Manages persisted transfer history.
class TransferHistoryNotifier extends StateNotifier<List<TransferRecord>> {
  TransferHistoryNotifier(this._prefs) : super([]) {
    _load();
  }

  final SharedPreferences _prefs;

  void _load() {
    final raw = _prefs.getString(_historyKey);
    if (raw == null || raw.isEmpty) return;

    try {
      final list = jsonDecode(raw) as List<dynamic>;
      state = list
          .map((e) => TransferRecord.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      // Corrupted data, start fresh.
      state = [];
    }
  }

  void _save() {
    final json = jsonEncode(state.map((r) => r.toJson()).toList());
    _prefs.setString(_historyKey, json);
  }

  /// Adds a finished transfer to the history.
  void add(TransferRecord record) {
    state = [record, ...state].take(_maxHistorySize).toList();
    _save();
  }

  /// Records a finished [Transfer] in the history.
  void recordTransfer(Transfer transfer) {
    if (transfer.status != TransferStatus.completed &&
        transfer.status != TransferStatus.failed) {
      return;
    }
    add(TransferRecord.fromTransfer(transfer));
  }

  /// Clears all history.
  void clear() {
    state = [];
    _save();
  }
}

/// Provider for transfer history.
final transferHistoryProvider =
    StateNotifierProvider<TransferHistoryNotifier, List<TransferRecord>>(
  (ref) {
    final prefs = ref.watch(sharedPreferencesProvider);
    return TransferHistoryNotifier(prefs);
  },
);

