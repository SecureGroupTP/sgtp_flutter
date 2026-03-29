import 'package:flutter/foundation.dart';

// ─── Log level ────────────────────────────────────────────────────────────────

enum LogLevel {
  debug,
  info,
  warn,
  error;

  String get tag => switch (this) {
        LogLevel.debug => 'DBG',
        LogLevel.info  => 'INF',
        LogLevel.warn  => 'WRN',
        LogLevel.error => 'ERR',
      };
}

// ─── Log entry ────────────────────────────────────────────────────────────────

class LogEntry {
  final DateTime time;
  final LogLevel level;
  final String tag;
  final String message;

  LogEntry({
    required this.time,
    required this.level,
    required this.tag,
    required this.message,
  });

  String get timeLabel {
    final h  = time.hour.toString().padLeft(2, '0');
    final mi = time.minute.toString().padLeft(2, '0');
    final s  = time.second.toString().padLeft(2, '0');
    final ms = time.millisecond.toString().padLeft(3, '0');
    return '$h:$mi:$s.$ms';
  }

  @override
  String toString() => '[$timeLabel] ${level.tag} [$tag] $message';
}

// ─── AppLogger ────────────────────────────────────────────────────────────────

class AppLogger {
  AppLogger._();

  static const int maxEntries = 2000;
  static final List<LogEntry> _logs = [];
  static final List<void Function(LogEntry)> _listeners = [];

  static void log(
    String message, {
    LogLevel level = LogLevel.info,
    String tag = 'APP',
  }) {
    final entry = LogEntry(
      time:    DateTime.now(),
      level:   level,
      tag:     tag,
      message: message,
    );
    _logs.add(entry);
    if (_logs.length > maxEntries) _logs.removeAt(0);
    for (final cb in _listeners) cb(entry);
    debugPrint('[SGTP/${entry.level.tag}/$tag] $message');
  }

  static void d(String msg, {String tag = 'APP'}) =>
      log(msg, level: LogLevel.debug, tag: tag);
  static void i(String msg, {String tag = 'APP'}) =>
      log(msg, level: LogLevel.info,  tag: tag);
  static void w(String msg, {String tag = 'APP'}) =>
      log(msg, level: LogLevel.warn,  tag: tag);
  static void e(String msg, {String tag = 'APP'}) =>
      log(msg, level: LogLevel.error, tag: tag);

  static List<LogEntry> get entries => List.unmodifiable(_logs);
  static String get fullText => _logs.map((e) => e.toString()).join('\n');
  static void clear() => _logs.clear();

  static void addListener(void Function(LogEntry) cb) => _listeners.add(cb);
  static void removeListener(void Function(LogEntry) cb) => _listeners.remove(cb);
}
