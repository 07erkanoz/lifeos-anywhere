/// A lightweight cancellation token for cooperative cancellation of
/// long-running sync operations (file transfers, directory scans).
///
/// Usage:
/// ```dart
/// final token = CancellationToken();
/// await sender.sendFile(..., cancel: token);
/// // To cancel:
/// token.cancel();
/// ```
class CancellationToken {
  bool _isCancelled = false;

  /// Whether cancellation has been requested.
  bool get isCancelled => _isCancelled;

  /// Request cancellation. Idempotent.
  void cancel() => _isCancelled = true;

  /// Throws [CancelledException] if cancellation has been requested.
  /// Call this at chunk boundaries inside streaming loops.
  void throwIfCancelled() {
    if (_isCancelled) throw CancelledException();
  }
}

/// Thrown when a [CancellationToken] is checked after cancellation.
class CancelledException implements Exception {
  @override
  String toString() => 'Operation cancelled';
}
