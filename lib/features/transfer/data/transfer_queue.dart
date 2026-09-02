import 'dart:async';
import 'dart:collection';

import 'package:anyware/core/logger.dart';
import 'package:anyware/features/discovery/domain/device.dart';
import 'package:anyware/features/transfer/data/file_sender.dart';
import 'package:anyware/features/transfer/domain/transfer.dart';

/// An item in the transfer queue.
class QueueItem {
  final String id;
  final Device target;
  final String filePath;
  final DateTime queuedAt;
  QueueStatus status;

  QueueItem({
    required this.id,
    required this.target,
    required this.filePath,
    required this.queuedAt,
    this.status = QueueStatus.queued,
  });
}

enum QueueStatus { queued, sending, completed, failed }

/// Manages a FIFO queue of file transfers, processing one at a time.
///
/// Usage:
/// ```dart
/// queue.enqueue(target, '/path/to/file.txt');
/// queue.enqueue(target, '/path/to/image.png');
/// // Files are sent sequentially; progress is emitted via [queueUpdates].
/// ```
class TransferQueue {
  TransferQueue({required this.sender, this.autoStart = true});

  static final _log = AppLogger('TransferQueue');

  final FileSender sender;

  /// Whether newly enqueued items should begin processing immediately.
  /// Production queues keep this enabled; tests and future scheduled queues
  /// can disable it while arranging pending items.
  final bool autoStart;

  final Queue<QueueItem> _queue = Queue<QueueItem>();
  final List<QueueItem> _history = [];
  bool _isProcessing = false;
  int _idCounter = 0;

  final StreamController<List<QueueItem>> _controller =
      StreamController<List<QueueItem>>.broadcast();

  /// Emits the current queue state whenever it changes.
  Stream<List<QueueItem>> get queueUpdates => _controller.stream;

  /// Current queue snapshot (pending + in-progress items).
  List<QueueItem> get pending => _queue.toList();

  /// Completed/failed items.
  List<QueueItem> get history => List.unmodifiable(_history);

  /// Total items waiting + in progress.
  int get length => _queue.length;

  /// Whether the queue is currently sending a file.
  bool get isProcessing => _isProcessing;

  /// Adds a file to the queue and starts processing if idle.
  QueueItem enqueue(Device target, String filePath) {
    final item = QueueItem(
      id: 'q_${++_idCounter}',
      target: target,
      filePath: filePath,
      queuedAt: DateTime.now(),
    );
    _queue.add(item);
    _emitState();

    if (autoStart && !_isProcessing) {
      _processNext();
    }

    return item;
  }

  /// Adds multiple files to the queue.
  List<QueueItem> enqueueAll(Device target, List<String> filePaths) {
    return filePaths.map((path) => enqueue(target, path)).toList();
  }

  /// Removes a queued (not yet sending) item from the queue.
  bool remove(String itemId) {
    final length = _queue.length;
    _queue.removeWhere(
      (item) => item.id == itemId && item.status == QueueStatus.queued,
    );
    if (_queue.length != length) {
      _emitState();
      return true;
    }
    return false;
  }

  /// Moves a queued item by [offset] positions. The item currently being sent
  /// is pinned to the first position and can never be reordered.
  bool move(String itemId, int offset) {
    if (offset == 0) return false;
    final items = _queue.toList();
    final from = items.indexWhere((item) => item.id == itemId);
    if (from < 0 || items[from].status != QueueStatus.queued) return false;

    final firstMovable =
        items.isNotEmpty && items.first.status == QueueStatus.sending ? 1 : 0;
    final to = (from + offset).clamp(firstMovable, items.length - 1).toInt();
    if (to == from) return false;

    final item = items.removeAt(from);
    items.insert(to, item);
    _queue
      ..clear()
      ..addAll(items);
    _emitState();
    return true;
  }

  /// Clears all queued (not in-progress) items.
  void clearPending() {
    _queue.removeWhere((item) => item.status == QueueStatus.queued);
    _emitState();
  }

  /// Cancels the current upload and removes every file still waiting.
  void cancelAll() {
    final hasSending = _queue.any((item) => item.status == QueueStatus.sending);
    _queue.removeWhere((item) => item.status == QueueStatus.queued);
    if (hasSending) sender.cancel();
    _emitState();
  }

  /// Clears the completed/failed history.
  void clearHistory() {
    _history.clear();
  }

  Future<void> _processNext() async {
    if (_queue.isEmpty) {
      _isProcessing = false;
      return;
    }

    _isProcessing = true;
    final item = _queue.first;
    item.status = QueueStatus.sending;
    _emitState();

    try {
      final transfer = await sender.sendFile(item.target, item.filePath);
      item.status = transfer.status == TransferStatus.completed
          ? QueueStatus.completed
          : QueueStatus.failed;
    } catch (e) {
      item.status = QueueStatus.failed;
      _log.error('Failed to send ${item.filePath}: $e', error: e);
    }

    _queue.removeFirst();
    _history.add(item);
    _emitState();

    // Process next item.
    await _processNext();
  }

  void _emitState() {
    if (!_controller.isClosed) {
      _controller.add(_queue.toList());
    }
  }

  void dispose() {
    _controller.close();
  }
}
