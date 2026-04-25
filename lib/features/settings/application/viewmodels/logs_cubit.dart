import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:logging/logging.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:sgtp_flutter/core/app_log.dart';
import 'package:sgtp_flutter/features/settings/application/viewmodels/logs_view_state.dart';

class LogsCubit extends Cubit<LogsViewState> {
  LogsCubit() : super(const LogsViewState()) {
    _sub = Logger.root.onRecord.listen(_onRecord);
    unawaited(_loadFromFile());
    unawaited(_restoreFilters());
  }

  StreamSubscription<LogRecord>? _sub;
  final List<LogEntry> _entries = [];

  LogLevel? _filterLevel;
  String? _filterName;
  LogsTimeRange _timeRange = LogsTimeRange.all;
  String _searchText = '';
  static const String _prefsKey = 'sgtp_logs_filters_v2';

  // ── Intents ──────────────────────────────────────────────────────────────

  void setFilterLevel(LogLevel? level) {
    _filterLevel = level;
    _buildState();
    unawaited(_saveFilters());
  }

  void setFilterName(String? name) {
    _filterName = name;
    _buildState();
    unawaited(_saveFilters());
  }

  void setSearchText(String text) {
    _searchText = text;
    _buildState();
    unawaited(_saveFilters());
  }

  void setTimeRange(LogsTimeRange value) {
    _timeRange = value;
    _buildState();
    unawaited(_saveFilters());
  }

  void resetFilters() {
    _filterLevel = null;
    _filterName = null;
    _timeRange = LogsTimeRange.all;
    _searchText = '';
    _buildState();
    unawaited(_saveFilters());
  }

  Future<void> clearLogs() async {
    _entries.clear();
    _buildState();
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/sgtp_logs.jsonl');
      if (await file.exists()) await file.writeAsString('');
    } catch (_) {}
  }

  String get visibleLogText => state.entries.map((e) => e.toString()).join('\n');

  // ── Private ──────────────────────────────────────────────────────────────

  void _onRecord(LogRecord record) {
    final entry = _recordToEntry(record);
    if (entry == null) return;
    _entries.add(entry);
    const maxEntries = 2000;
    if (_entries.length > maxEntries) _entries.removeAt(0);
    _buildState();
  }

  LogEntry? _recordToEntry(LogRecord record) {
    final payload = record.object is LogPayload
        ? record.object as LogPayload
        : LogPayload(
            message: record.message,
            messageTemplate: record.message,
            parameters: const {},
          );
    final level = _levelFromLogging(record.level);
    if (level == null) return null;
    return LogEntry(
      time: record.time,
      level: level,
      name: record.loggerName,
      message: payload.message,
      messageTemplate: payload.messageTemplate,
      parameters: payload.parameters,
      error: record.error?.toString(),
      stackTrace: record.stackTrace?.toString(),
    );
  }

  Future<void> _loadFromFile() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/sgtp_logs.jsonl');
      if (!await file.exists()) return;
      final lines = await file.readAsLines();
      for (final line in lines) {
        final trimmed = line.trim();
        if (trimmed.isEmpty) continue;
        final entry = _parseJsonLine(trimmed);
        if (entry != null) _entries.add(entry);
      }
      const maxEntries = 2000;
      if (_entries.length > maxEntries) {
        _entries.removeRange(0, _entries.length - maxEntries);
      }
      _buildState();
    } catch (_) {}
  }

  LogEntry? _parseJsonLine(String line) {
    try {
      final map = jsonDecode(line) as Map<String, dynamic>;
      final level = LogLevel.byName((map['level'] as String?) ?? '');
      if (level == null) return null;
      final time = DateTime.tryParse((map['@t'] as String?) ?? '');
      if (time == null) return null;
      final rawParams = map['@p'];
      final parameters = rawParams is Map<String, dynamic>
          ? Map<String, Object?>.from(rawParams)
          : const <String, Object?>{};
      return LogEntry(
        time: time.toLocal(),
        level: level,
        name: (map['name'] as String?) ?? '',
        message: (map['@m'] as String?) ?? '',
        messageTemplate: (map['@mt'] as String?) ?? '',
        parameters: parameters,
        error: map['@e'] as String?,
        stackTrace: map['@st'] as String?,
      );
    } catch (_) {
      return null;
    }
  }

  void _buildState() {
    if (isClosed) return;

    final names = _entries
        .map((e) => e.name)
        .where((n) => n.isNotEmpty)
        .toSet()
        .toList()
      ..sort();

    var list = List<LogEntry>.from(_entries);

    if (_filterLevel != null) {
      list = list.where((e) => e.level == _filterLevel).toList();
    }
    if (_filterName != null && _filterName!.isNotEmpty) {
      list = list.where((e) => e.name == _filterName).toList();
    }

    final cutoff = _timeCutoff(_timeRange);
    if (cutoff != null) {
      list = list.where((e) => e.time.isAfter(cutoff)).toList();
    }

    final q = _searchText.trim().toLowerCase();
    if (q.isNotEmpty) {
      list = list.where((e) {
        return e.message.toLowerCase().contains(q) ||
            e.name.toLowerCase().contains(q) ||
            e.messageTemplate.toLowerCase().contains(q);
      }).toList();
    }

    emit(LogsViewState(
      entries: list,
      totalCount: _entries.length,
      filterLevel: _filterLevel,
      filterName: _filterName,
      timeRange: _timeRange,
      searchText: _searchText,
      availableNames: names,
    ));
  }

  DateTime? _timeCutoff(LogsTimeRange range) {
    final now = DateTime.now();
    return switch (range) {
      LogsTimeRange.all => null,
      LogsTimeRange.m5 => now.subtract(const Duration(minutes: 5)),
      LogsTimeRange.m15 => now.subtract(const Duration(minutes: 15)),
      LogsTimeRange.h1 => now.subtract(const Duration(hours: 1)),
      LogsTimeRange.h24 => now.subtract(const Duration(hours: 24)),
    };
  }

  LogLevel? _levelFromLogging(Level level) {
    if (level == Level.FINE || level == Level.FINER || level == Level.FINEST) {
      return LogLevel.debug;
    }
    if (level == Level.INFO) return LogLevel.info;
    if (level == Level.WARNING) return LogLevel.warning;
    if (level == Level.SEVERE || level == Level.SHOUT) return LogLevel.error;
    return null;
  }

  Future<void> _restoreFilters() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw == null || raw.trim().isEmpty) return;
      final map = jsonDecode(raw) as Map<String, dynamic>;
      _filterLevel = LogLevel.byName((map['level'] as String?) ?? '');
      _filterName = (map['name'] as String?)?.trim();
      _timeRange = _timeRangeByName((map['timeRange'] as String?) ?? '') ??
          LogsTimeRange.all;
      _searchText = (map['searchText'] as String?) ?? '';
      _buildState();
    } catch (_) {}
  }

  Future<void> _saveFilters() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _prefsKey,
        jsonEncode({
          'level': _filterLevel?.name,
          'name': _filterName,
          'timeRange': _timeRange.name,
          'searchText': _searchText,
        }),
      );
    } catch (_) {}
  }

  LogsTimeRange? _timeRangeByName(String name) {
    for (final v in LogsTimeRange.values) {
      if (v.name == name) return v;
    }
    return null;
  }

  @override
  Future<void> close() async {
    await _sub?.cancel();
    return super.close();
  }
}
