import 'package:sgtp_flutter/core/app_logger.dart';

enum LogsTimeRange {
  all,
  m5,
  m15,
  h1,
  h24;

  String get label => switch (this) {
        LogsTimeRange.all => 'All time',
        LogsTimeRange.m5 => '5m',
        LogsTimeRange.m15 => '15m',
        LogsTimeRange.h1 => '1h',
        LogsTimeRange.h24 => '24h',
      };
}

class LogsViewState {
  const LogsViewState({
    this.entries = const [],
    this.totalCount = 0,
    this.filterLevel,
    this.filterTag,
    this.packetsOnly = false,
    this.filterPacketType,
    this.filterDirection,
    this.issuesOnly = false,
    this.timeRange = LogsTimeRange.all,
    this.searchText = '',
    this.availableTags = const [],
    this.availablePacketTypes = const [],
  });

  final List<LogEntry> entries;
  final int totalCount;
  final LogLevel? filterLevel;
  final String? filterTag;
  final bool packetsOnly;
  final String? filterPacketType;
  final PacketDirection? filterDirection;
  final bool issuesOnly;
  final LogsTimeRange timeRange;
  final String searchText;
  final List<String> availableTags;
  final List<String> availablePacketTypes;
}
