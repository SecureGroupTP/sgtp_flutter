import 'package:sgtp_flutter/core/app_logger.dart';

class LogsViewState {
  const LogsViewState({
    this.entries = const [],
    this.totalCount = 0,
    this.filterLevel,
    this.searchText = '',
  });

  final List<LogEntry> entries;
  final int totalCount;
  final LogLevel? filterLevel;
  final String searchText;
}
