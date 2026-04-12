import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

import 'package:sgtp_flutter/core/app_log.dart';

/// Wires the two logging sinks (console + JSONL file) onto [Logger.root].
///
/// Call [LogSetup.init] once at app startup before any [AppLog] usage.
class LogSetup {
  LogSetup._();

  static IOSink? _fileSink;

  /// [logFilePath] — absolute path to the JSONL log file.
  static void init(String logFilePath) {
    Logger.root.level = Level.ALL;

    final file = File(logFilePath);
    _fileSink = file.openWrite(mode: FileMode.append);

    Logger.root.onRecord.listen(_handle);
  }

  static void _handle(LogRecord record) {
    final payload = record.object is LogPayload
        ? record.object as LogPayload
        : LogPayload(
            message: record.message,
            messageTemplate: record.message,
            parameters: const {},
          );

    // ── Console ──────────────────────────────────────────────────────────
    final dt = record.time;
    final month = dt.month.toString().padLeft(2, '0');
    final day = dt.day.toString().padLeft(2, '0');
    final year = dt.year.toString();
    final hour = dt.hour.toString().padLeft(2, '0');
    final minute = dt.minute.toString().padLeft(2, '0');
    final second = dt.second.toString().padLeft(2, '0');
    final ms = dt.millisecond.toString().padLeft(3, '0');
    final dateStr = '$month/$day/$year $hour:$minute:$second.$ms';

    final consoleLine =
        '[$dateStr ${record.loggerName}] ${payload.message}';
    debugPrint(consoleLine);

    // ── File (JSONL) ──────────────────────────────────────────────────────
    final sink = _fileSink;
    if (sink == null) return;

    final errorStr = record.error?.toString();
    final stStr = record.stackTrace?.toString();

    final jsonMap = <String, Object?>{
      '@t': record.time.toUtc().toIso8601String(),
      'level': _levelName(record.level),
      'name': record.loggerName,
      '@m': payload.message,
      '@mt': payload.messageTemplate,
      '@p': payload.parameters.isEmpty ? null : payload.parameters,
      '@e': errorStr,
      '@st': stStr,
    };

    try {
      sink.writeln(jsonEncode(jsonMap));
    } catch (_) {}
  }

  static String _levelName(Level level) {
    if (level == Level.FINE || level == Level.FINER || level == Level.FINEST) {
      return 'debug';
    }
    if (level == Level.INFO) return 'info';
    if (level == Level.WARNING) return 'warning';
    if (level == Level.SEVERE || level == Level.SHOUT) return 'error';
    return level.name.toLowerCase();
  }

  static Future<void> close() async {
    await _fileSink?.flush();
    await _fileSink?.close();
    _fileSink = null;
  }
}
