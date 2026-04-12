import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

import 'package:sgtp_flutter/core/app_log.dart';

// ── ANSI escape helpers ────────────────────────────────────────────────────

const _r = '\x1B[0m'; // reset

const _dimGrey = '\x1B[2;37m';
const _grey = '\x1B[37m';
const _cyan = '\x1B[36m';

// Level badge colours  (bold + colour)
const _lvlDebug = '\x1B[2;37m'; // dim grey
const _lvlInfo = '\x1B[1;36m'; // bold cyan
const _lvlWarn = '\x1B[1;33m'; // bold yellow
const _lvlError = '\x1B[1;31m'; // bold red

// Message text colours
const _msgDebug = '\x1B[37m'; // grey
const _msgInfo = '\x1B[97m'; // bright white
const _msgWarn = '\x1B[33m'; // yellow
const _msgError = '\x1B[91m'; // bright red

// Parameter value colours
const _valString = '\x1B[96m'; // bright cyan (teal)  — strings
const _valNumber = '\x1B[35m'; // magenta (purple)    — int / double
const _valBool = '\x1B[1;35m'; // bold magenta        — bool
const _valNull = '\x1B[34m'; // blue                  — null
const _valOther = '\x1B[32m'; // green                — everything else

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
    final hour = dt.hour.toString().padLeft(2, '0');
    final minute = dt.minute.toString().padLeft(2, '0');
    final second = dt.second.toString().padLeft(2, '0');
    final ms = dt.millisecond.toString().padLeft(3, '0');

    final String consoleLine;

    if (kDebugMode) {
      // Serilog-style coloured output:
      //   [HH:mm:ss.fff LVL] SourceContext Message
      final lvlColor = _levelAnsiColor(record.level);
      final msgColor = _messageAnsiColor(record.level);
      final badge = _levelBadge(record.level);

      final renderedMsg = _renderColored(
        payload.messageTemplate,
        payload.parameters,
        msgColor,
      );

      consoleLine = '$_dimGrey[$_r$_grey$hour:$minute:$second.$ms$_r '
          '$lvlColor$badge$_r'
          '$_dimGrey]$_r '
          '$_cyan${record.loggerName}$_r '
          '$msgColor$renderedMsg$_r'
          '${record.error != null ? '\n  $_lvlError${record.error}$_r' : ''}';
    } else {
      final month = dt.month.toString().padLeft(2, '0');
      final day = dt.day.toString().padLeft(2, '0');
      final year = dt.year.toString();
      consoleLine =
          '[$month/$day/$year $hour:$minute:$second.$ms ${record.loggerName}] '
          '${payload.message}';
    }

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

  // ── Helpers ───────────────────────────────────────────────────────────────

  /// Renders [template] replacing `{key}` placeholders with ANSI-coloured
  /// values from [parameters]. Literal text outside placeholders is left in
  /// [msgColor] so the surrounding message stays its level colour.
  static String _renderColored(
    String template,
    Map<String, Object?> parameters,
    String msgColor,
  ) {
    if (parameters.isEmpty) return template;
    return template.replaceAllMapped(
      RegExp(r'\{(\w+)\}'),
      (m) {
        final key = m.group(1)!;
        if (!parameters.containsKey(key)) return m.group(0)!;
        return '${_colorValue(parameters[key])}$msgColor';
      },
    );
  }

  /// Wraps [value] in the ANSI colour matching its runtime type.
  static String _colorValue(Object? value) {
    if (value == null) return '$_valNull(null)$_r';
    if (value is String) return '$_valString"$value"$_r';
    if (value is bool) return '$_valBool$value$_r';
    if (value is num) return '$_valNumber$value$_r';
    return '$_valOther$value$_r';
  }

  static String _levelBadge(Level level) {
    if (level == Level.FINE || level == Level.FINER || level == Level.FINEST) {
      return 'DBG';
    }
    if (level == Level.INFO) return 'INF';
    if (level == Level.WARNING) return 'WRN';
    if (level == Level.SEVERE || level == Level.SHOUT) return 'ERR';
    return level.name.substring(0, 3).toUpperCase();
  }

  static String _levelAnsiColor(Level level) {
    if (level == Level.FINE || level == Level.FINER || level == Level.FINEST) {
      return _lvlDebug;
    }
    if (level == Level.INFO) return _lvlInfo;
    if (level == Level.WARNING) return _lvlWarn;
    if (level == Level.SEVERE || level == Level.SHOUT) return _lvlError;
    return _grey;
  }

  static String _messageAnsiColor(Level level) {
    if (level == Level.FINE || level == Level.FINER || level == Level.FINEST) {
      return _msgDebug;
    }
    if (level == Level.INFO) return _msgInfo;
    if (level == Level.WARNING) return _msgWarn;
    if (level == Level.SEVERE || level == Level.SHOUT) return _msgError;
    return _grey;
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
