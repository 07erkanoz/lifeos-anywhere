import 'package:anyware/features/transfer/data/transfer_history.dart';
import 'package:anyware/features/clipboard/data/clipboard_service.dart';

/// A unified timeline event that can represent a file transfer,
/// clipboard sync, or folder sync action.
class TimelineEvent implements Comparable<TimelineEvent> {
  final TimelineEventType type;
  final DateTime timestamp;
  final String title;
  final String subtitle;
  final bool succeeded;
  final int? sizeBytes;

  const TimelineEvent({
    required this.type,
    required this.timestamp,
    required this.title,
    required this.subtitle,
    this.succeeded = true,
    this.sizeBytes,
  });

  /// Creates a timeline event from a [TransferRecord].
  factory TimelineEvent.fromTransfer(TransferRecord record) {
    return TimelineEvent(
      type: record.isSending
          ? TimelineEventType.fileSent
          : TimelineEventType.fileReceived,
      timestamp: record.timestamp,
      title: record.fileName,
      subtitle: record.deviceName,
      succeeded: record.succeeded,
      sizeBytes: record.fileSize,
    );
  }

  /// Creates a timeline event from a [ClipboardEntry].
  factory TimelineEvent.fromClipboard(ClipboardEntry entry) {
    final preview = entry.text.length > 60
        ? '${entry.text.substring(0, 60)}…'
        : entry.text;

    return TimelineEvent(
      type: TimelineEventType.clipboardSync,
      timestamp: entry.timestamp,
      title: entry.type == ClipboardContentType.image
          ? 'Image'
          : preview,
      subtitle: entry.senderName,
    );
  }

  /// Formatted file size or empty string if not applicable.
  String get formattedSize {
    if (sizeBytes == null || sizeBytes == 0) return '';
    final b = sizeBytes!;
    if (b < 1024) return '$b B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
    if (b < 1024 * 1024 * 1024) {
      return '${(b / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(b / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  @override
  int compareTo(TimelineEvent other) =>
      other.timestamp.compareTo(timestamp); // Newest first.
}

enum TimelineEventType {
  fileSent,
  fileReceived,
  clipboardSync,
}
