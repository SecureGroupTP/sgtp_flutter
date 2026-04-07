import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:sgtp_flutter/core/app_logger.dart';
import 'package:sgtp_flutter/features/settings/application/viewmodels/logs_view_state.dart';

class LogsCubit extends Cubit<LogsViewState> {
  LogsCubit() : super(const LogsViewState()) {
    AppLogger.addListener(_onNewLog);
    _buildState();
  }

  LogLevel? _filterLevel;
  String _searchText = '';

  // ── Intents ──────────────────────────────────────────────────────────────

  void setFilterLevel(LogLevel? level) {
    _filterLevel = level;
    _buildState();
  }

  void setSearchText(String text) {
    _searchText = text;
    _buildState();
  }

  void clearLogs() {
    AppLogger.clear();
    _buildState();
  }

  String get fullLogText => AppLogger.fullText;

  /// Called by the AppLogger listener — triggers a rebuild.
  void _onNewLog(LogEntry _) {
    _buildState();
  }

  // ── Private ──────────────────────────────────────────────────────────────

  void _buildState() {
    if (isClosed) return;
    var list = AppLogger.entries;
    if (_filterLevel != null) {
      list = list.where((e) => e.level == _filterLevel).toList();
    }
    final q = _searchText.trim().toLowerCase();
    if (q.isNotEmpty) {
      list = list.where((e) => e.message.toLowerCase().contains(q)).toList();
    }
    emit(LogsViewState(
      entries: list,
      totalCount: AppLogger.entries.length,
      filterLevel: _filterLevel,
      searchText: _searchText,
    ));
  }

  @override
  Future<void> close() {
    AppLogger.removeListener(_onNewLog);
    return super.close();
  }
}
