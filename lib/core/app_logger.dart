import 'package:flutter/foundation.dart';

// ─── Log level ────────────────────────────────────────────────────────────────

enum LogLevel {
  debug,
  info,
  warn,
  error;

  String get tag => switch (this) {
        LogLevel.debug => 'DBG',
        LogLevel.info => 'INF',
        LogLevel.warn => 'WRN',
        LogLevel.error => 'ERR',
      };
}

enum PacketDirection {
  none,
  inbound,
  outbound;

  String get label => switch (this) {
        PacketDirection.none => 'NONE',
        PacketDirection.inbound => 'IN',
        PacketDirection.outbound => 'OUT',
      };
}

// ─── Log entry ────────────────────────────────────────────────────────────────

class LogEntry {
  final DateTime time;
  final LogLevel level;
  final String tag;
  final String? source;
  final String message;
  final String? packetTypeName;
  final String? packetTypeCode;
  final PacketDirection packetDirection;
  final bool packetDropped;
  final bool packetError;
  final Map<String, String> attributes;

  LogEntry({
    required this.time,
    required this.level,
    required this.tag,
    this.source,
    required this.message,
    this.packetTypeName,
    this.packetTypeCode,
    this.packetDirection = PacketDirection.none,
    this.packetDropped = false,
    this.packetError = false,
    this.attributes = const {},
  });

  String get timeLabel {
    final h = time.hour.toString().padLeft(2, '0');
    final mi = time.minute.toString().padLeft(2, '0');
    final s = time.second.toString().padLeft(2, '0');
    final ms = time.millisecond.toString().padLeft(3, '0');
    return '$h:$mi:$s.$ms';
  }

  String get metadataLabel {
    final parts = <String>[];
    if (source != null && source!.trim().isNotEmpty) {
      parts.add('src=${source!.trim()}');
    }
    if (packetTypeName != null && packetTypeName!.trim().isNotEmpty) {
      final pktName = packetTypeName!.trim();
      final pktCode = (packetTypeCode ?? '').trim();
      parts.add(
        pktCode.isEmpty ? 'pkt=$pktName' : 'pkt=$pktName($pktCode)',
      );
      if (packetDirection != PacketDirection.none) {
        parts.add('dir=${packetDirection.label}');
      }
      if (packetDropped) parts.add('dropped');
      if (packetError) parts.add('pkt_err');
    }
    if (attributes.isNotEmpty) {
      final keys = attributes.keys.toList()..sort();
      for (final k in keys) {
        final v = attributes[k];
        if (v == null || v.isEmpty) continue;
        parts.add('$k=$v');
      }
    }
    return parts.join(' ');
  }

  @override
  String toString() {
    final meta = metadataLabel;
    return meta.isEmpty
        ? '[$timeLabel] ${level.tag} [$tag] $message'
        : '[$timeLabel] ${level.tag} [$tag] {$meta} $message';
  }
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
    String? source,
    String? packetTypeName,
    String? packetTypeCode,
    PacketDirection packetDirection = PacketDirection.none,
    bool packetDropped = false,
    bool packetError = false,
    Map<String, String> attributes = const {},
  }) {
    final entry = LogEntry(
      time: DateTime.now(),
      level: level,
      tag: tag,
      source: source,
      message: message,
      packetTypeName: packetTypeName,
      packetTypeCode: packetTypeCode,
      packetDirection: packetDirection,
      packetDropped: packetDropped,
      packetError: packetError,
      attributes: attributes,
    );
    _logs.add(entry);
    if (_logs.length > maxEntries) _logs.removeAt(0);
    for (final cb in _listeners) {
      cb(entry);
    }
    final sourcePart =
        (source ?? '').trim().isEmpty ? '' : '/${source!.trim()}';
    debugPrint('[SGTP/${entry.level.tag}/$tag$sourcePart] $message');
  }

  static void d(
    String msg, {
    String tag = 'APP',
    String? source,
    String? packetTypeName,
    String? packetTypeCode,
    PacketDirection packetDirection = PacketDirection.none,
    bool packetDropped = false,
    bool packetError = false,
    Map<String, String> attributes = const {},
  }) =>
      log(
        msg,
        level: LogLevel.debug,
        tag: tag,
        source: source,
        packetTypeName: packetTypeName,
        packetTypeCode: packetTypeCode,
        packetDirection: packetDirection,
        packetDropped: packetDropped,
        packetError: packetError,
        attributes: attributes,
      );
  static void i(
    String msg, {
    String tag = 'APP',
    String? source,
    String? packetTypeName,
    String? packetTypeCode,
    PacketDirection packetDirection = PacketDirection.none,
    bool packetDropped = false,
    bool packetError = false,
    Map<String, String> attributes = const {},
  }) =>
      log(
        msg,
        level: LogLevel.info,
        tag: tag,
        source: source,
        packetTypeName: packetTypeName,
        packetTypeCode: packetTypeCode,
        packetDirection: packetDirection,
        packetDropped: packetDropped,
        packetError: packetError,
        attributes: attributes,
      );
  static void w(
    String msg, {
    String tag = 'APP',
    String? source,
    String? packetTypeName,
    String? packetTypeCode,
    PacketDirection packetDirection = PacketDirection.none,
    bool packetDropped = false,
    bool packetError = false,
    Map<String, String> attributes = const {},
  }) =>
      log(
        msg,
        level: LogLevel.warn,
        tag: tag,
        source: source,
        packetTypeName: packetTypeName,
        packetTypeCode: packetTypeCode,
        packetDirection: packetDirection,
        packetDropped: packetDropped,
        packetError: packetError,
        attributes: attributes,
      );
  static void e(
    String msg, {
    String tag = 'APP',
    String? source,
    String? packetTypeName,
    String? packetTypeCode,
    PacketDirection packetDirection = PacketDirection.none,
    bool packetDropped = false,
    bool packetError = false,
    Map<String, String> attributes = const {},
  }) =>
      log(
        msg,
        level: LogLevel.error,
        tag: tag,
        source: source,
        packetTypeName: packetTypeName,
        packetTypeCode: packetTypeCode,
        packetDirection: packetDirection,
        packetDropped: packetDropped,
        packetError: packetError,
        attributes: attributes,
      );

  static void packet(
    String message, {
    required int packetType,
    required PacketDirection direction,
    LogLevel level = LogLevel.debug,
    String tag = 'PKT',
    String source = 'SgtpClient',
    String? packetTypeName,
    bool dropped = false,
    bool error = false,
    Map<String, String> attributes = const {},
  }) {
    final code = '0x${packetType.toRadixString(16).padLeft(4, '0')}';
    log(
      message,
      level: level,
      tag: tag,
      source: source,
      packetTypeName: packetTypeName,
      packetTypeCode: code,
      packetDirection: direction,
      packetDropped: dropped,
      packetError: error,
      attributes: attributes,
    );
  }

  static List<LogEntry> get entries => List.unmodifiable(_logs);
  static String get fullText => _logs.map((e) => e.toString()).join('\n');
  static void clear() => _logs.clear();

  static void addListener(void Function(LogEntry) cb) => _listeners.add(cb);
  static void removeListener(void Function(LogEntry) cb) =>
      _listeners.remove(cb);
}
