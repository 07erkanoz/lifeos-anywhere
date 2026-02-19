import 'dart:collection';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// Log severity levels ordered by verbosity.
enum LogLevel {
  debug,
  info,
  warning,
  error,
}

/// A single structured log entry.
class LogEntry {
  final DateTime timestamp;
  final LogLevel level;
  final String tag;
  final String message;
  final Object? error;
  final StackTrace? stackTrace;

  const LogEntry({
    required this.timestamp,
    required this.level,
    required this.tag,
    required this.message,
    this.error,
    this.stackTrace,
  });

  /// Formatted one-line representation for console output.
  String get formatted {
    final ts = _formatTimestamp(timestamp);
    final lvl = level.name.toUpperCase().padRight(5);
    final err = error != null ? ' | $error' : '';
    return '[$ts] $lvl $tag: $message$err';
  }

  Map<String, dynamic> toJson() => {
    'timestamp': timestamp.toIso8601String(),
    'level': level.name,
    'tag': tag,
    'message': message,
    if (error != null) 'error': error.toString(),
  };

  static String _formatTimestamp(DateTime dt) {
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    final s = dt.second.toString().padLeft(2, '0');
    final ms = dt.millisecond.toString().padLeft(3, '0');
    return '$h:$m:$s.$ms';
  }
}

/// Central structured logger for the application.
///
/// Usage:
/// ```dart
/// final _log = AppLogger('FileServer');
/// _log.info('Started on port 42017');
/// _log.error('Failed to bind', error: e);
/// ```
class AppLogger {
  AppLogger(this.tag);

  /// The tag/category for this logger instance (e.g. 'FileServer').
  final String tag;

  /// Minimum level to output. Messages below this level are discarded.
  static LogLevel minLevel = kDebugMode ? LogLevel.debug : LogLevel.info;

  /// In-memory ring buffer of recent log entries for diagnostics.
  static final Queue<LogEntry> _buffer = Queue<LogEntry>();

  /// Maximum entries kept in the ring buffer.
  static const int maxBufferSize = 500;

  /// Optional file sink for persistent logging.
  static IOSink? _fileSink;

  /// Initializes file logging to [path]. Call once at app startup.
  static void initFileLogging(String path) {
    try {
      final file = File(path);
      file.parent.createSync(recursive: true);
      _fileSink = file.openWrite(mode: FileMode.append);
    } catch (e) {
      debugPrint('AppLogger: Failed to init file logging: $e');
    }
  }

  /// Returns a snapshot of the in-memory log buffer.
  static List<LogEntry> get recentLogs => _buffer.toList();

  /// Clears the in-memory log buffer.
  static void clearBuffer() => _buffer.clear();

  /// Flushes and closes the file sink.
  static Future<void> dispose() async {
    await _fileSink?.flush();
    await _fileSink?.close();
    _fileSink = null;
  }

  // Convenience methods -------------------------------------------------------

  void debug(String message, {Object? error, StackTrace? stackTrace}) =>
      _log(LogLevel.debug, message, error: error, stackTrace: stackTrace);

  void info(String message, {Object? error, StackTrace? stackTrace}) =>
      _log(LogLevel.info, message, error: error, stackTrace: stackTrace);

  void warning(String message, {Object? error, StackTrace? stackTrace}) =>
      _log(LogLevel.warning, message, error: error, stackTrace: stackTrace);

  void error(String message, {Object? error, StackTrace? stackTrace}) =>
      _log(LogLevel.error, message, error: error, stackTrace: stackTrace);

  // Core ----------------------------------------------------------------------

  void _log(
    LogLevel level,
    String message, {
    Object? error,
    StackTrace? stackTrace,
  }) {
    if (level.index < minLevel.index) return;

    final entry = LogEntry(
      timestamp: DateTime.now(),
      level: level,
      tag: tag,
      message: message,
      error: error,
      stackTrace: stackTrace,
    );

    // Ring buffer.
    _buffer.addLast(entry);
    while (_buffer.length > maxBufferSize) {
      _buffer.removeFirst();
    }

    // Console output.
    debugPrint(entry.formatted);

    // File output.
    _fileSink?.writeln(entry.formatted);
    if (stackTrace != null) {
      _fileSink?.writeln(stackTrace.toString());
    }
  }
}
