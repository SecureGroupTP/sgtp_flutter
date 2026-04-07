import 'dart:async';
import 'dart:convert';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:sgtp_flutter/core/app_logger.dart';
import 'package:sgtp_flutter/features/settings/application/viewmodels/logs_view_state.dart';

class LogsCubit extends Cubit<LogsViewState> {
  LogsCubit() : super(const LogsViewState()) {
    AppLogger.addListener(_onNewLog);
    _buildState();
    unawaited(_restoreFilters());
  }

  LogLevel? _filterLevel;
  String? _filterTag;
  bool _packetsOnly = false;
  String? _filterPacketType;
  PacketDirection? _filterDirection;
  bool _issuesOnly = false;
  LogsTimeRange _timeRange = LogsTimeRange.all;
  String _searchText = '';
  static const String _prefsKey = 'sgtp_logs_filters_v1';

  // ── Intents ──────────────────────────────────────────────────────────────

  void setFilterLevel(LogLevel? level) {
    _filterLevel = level;
    _buildState();
    unawaited(_saveFilters());
  }

  void setSearchText(String text) {
    _searchText = text;
    _buildState();
    unawaited(_saveFilters());
  }

  void setTag(String? tag) {
    _filterTag = tag;
    _buildState();
    unawaited(_saveFilters());
  }

  void setPacketsOnly(bool value) {
    _packetsOnly = value;
    if (value) _filterTag = 'PKT';
    _buildState();
    unawaited(_saveFilters());
  }

  void setPacketType(String? packetType) {
    _filterPacketType = packetType;
    _buildState();
    unawaited(_saveFilters());
  }

  void setDirection(PacketDirection? direction) {
    _filterDirection = direction;
    _buildState();
    unawaited(_saveFilters());
  }

  void setIssuesOnly(bool value) {
    _issuesOnly = value;
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
    _filterTag = null;
    _packetsOnly = false;
    _filterPacketType = null;
    _filterDirection = null;
    _issuesOnly = false;
    _timeRange = LogsTimeRange.all;
    _searchText = '';
    _buildState();
    unawaited(_saveFilters());
  }

  void clearLogs() {
    AppLogger.clear();
    _buildState();
  }

  String get fullLogText => AppLogger.fullText;
  String get visibleLogText =>
      state.entries.map((e) => e.toString()).join('\n');

  /// Called by the AppLogger listener — triggers a rebuild.
  void _onNewLog(LogEntry _) {
    _buildState();
  }

  // ── Private ──────────────────────────────────────────────────────────────

  void _buildState() {
    if (isClosed) return;
    final allEntries = AppLogger.entries;

    final tags = allEntries
        .map((e) => e.tag.trim())
        .where((e) => e.isNotEmpty)
        .toSet()
        .toList()
      ..sort();
    final packetTypes = allEntries
        .map((e) => (e.packetTypeName ?? '').trim())
        .where((e) => e.isNotEmpty)
        .toSet()
        .toList()
      ..sort();

    var list = allEntries;
    if (_filterLevel != null) {
      list = list.where((e) => e.level == _filterLevel).toList();
    }
    if (_packetsOnly) {
      list = list.where((e) => e.tag == 'PKT').toList();
    }
    if (_filterTag != null && _filterTag!.isNotEmpty) {
      list = list.where((e) => e.tag == _filterTag).toList();
    }
    if (_filterPacketType != null && _filterPacketType!.isNotEmpty) {
      list = list.where((e) => e.packetTypeName == _filterPacketType).toList();
    }
    if (_filterDirection != null) {
      list = list.where((e) => e.packetDirection == _filterDirection).toList();
    }
    if (_issuesOnly) {
      list = list.where((e) => e.packetDropped || e.packetError).toList();
    }

    final cutoff = _timeCutoff(_timeRange);
    if (cutoff != null) {
      list = list.where((e) => e.time.isAfter(cutoff)).toList();
    }

    final q = _searchText.trim().toLowerCase();
    if (q.isNotEmpty) {
      list = list.where((e) {
        final source = (e.source ?? '').toLowerCase();
        final pktName = (e.packetTypeName ?? '').toLowerCase();
        final pktCode = (e.packetTypeCode ?? '').toLowerCase();
        return e.message.toLowerCase().contains(q) ||
            e.tag.toLowerCase().contains(q) ||
            source.contains(q) ||
            pktName.contains(q) ||
            pktCode.contains(q);
      }).toList();
    }

    emit(LogsViewState(
      entries: list,
      totalCount: allEntries.length,
      filterLevel: _filterLevel,
      filterTag: _filterTag,
      packetsOnly: _packetsOnly,
      filterPacketType: _filterPacketType,
      filterDirection: _filterDirection,
      issuesOnly: _issuesOnly,
      timeRange: _timeRange,
      searchText: _searchText,
      availableTags: tags,
      availablePacketTypes: packetTypes,
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

  Future<void> _restoreFilters() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw == null || raw.trim().isEmpty) return;
      final jsonMap = jsonDecode(raw) as Map<String, dynamic>;
      final levelName = (jsonMap['level'] as String?)?.trim();
      _filterLevel = levelName == null ? null : _logLevelByName(levelName);
      _filterTag = (jsonMap['tag'] as String?)?.trim();
      _packetsOnly = (jsonMap['packetsOnly'] as bool?) ?? false;
      _filterPacketType = (jsonMap['packetType'] as String?)?.trim();
      final dirName = (jsonMap['direction'] as String?)?.trim();
      _filterDirection = dirName == null ? null : _directionByName(dirName);
      _issuesOnly = (jsonMap['issuesOnly'] as bool?) ?? false;
      final rangeName =
          ((jsonMap['timeRange'] as String?)?.trim() ?? LogsTimeRange.all.name);
      _timeRange = _timeRangeByName(rangeName) ?? LogsTimeRange.all;
      _searchText = (jsonMap['searchText'] as String?) ?? '';
      _buildState();
    } catch (_) {}
  }

  Future<void> _saveFilters() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final payload = <String, dynamic>{
        'level': _filterLevel?.name,
        'tag': _filterTag,
        'packetsOnly': _packetsOnly,
        'packetType': _filterPacketType,
        'direction': _filterDirection?.name,
        'issuesOnly': _issuesOnly,
        'timeRange': _timeRange.name,
        'searchText': _searchText,
      };
      await prefs.setString(_prefsKey, jsonEncode(payload));
    } catch (_) {}
  }

  LogLevel? _logLevelByName(String name) {
    for (final value in LogLevel.values) {
      if (value.name == name) return value;
    }
    return null;
  }

  PacketDirection? _directionByName(String name) {
    for (final value in PacketDirection.values) {
      if (value.name == name) return value;
    }
    return null;
  }

  LogsTimeRange? _timeRangeByName(String name) {
    for (final value in LogsTimeRange.values) {
      if (value.name == name) return value;
    }
    return null;
  }

  @override
  Future<void> close() {
    AppLogger.removeListener(_onNewLog);
    return super.close();
  }
}
