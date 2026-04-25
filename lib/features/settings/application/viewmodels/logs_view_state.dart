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

enum LogLevel {
  debug,
  info,
  warning,
  error;

  String get label => switch (this) {
        LogLevel.debug => 'Debug',
        LogLevel.info => 'Info',
        LogLevel.warning => 'Warning',
        LogLevel.error => 'Error',
      };

  static LogLevel? byName(String name) {
    for (final v in values) {
      if (v.name == name) return v;
    }
    return null;
  }
}

class LogEntry {
  final DateTime time;
  final LogLevel level;
  final String name;
  final String message;
  final String messageTemplate;
  final Map<String, Object?> parameters;
  final String? error;
  final String? stackTrace;

  const LogEntry({
    required this.time,
    required this.level,
    required this.name,
    required this.message,
    required this.messageTemplate,
    required this.parameters,
    this.error,
    this.stackTrace,
  });

  String get timeLabel {
    final h = time.hour.toString().padLeft(2, '0');
    final mi = time.minute.toString().padLeft(2, '0');
    final s = time.second.toString().padLeft(2, '0');
    final ms = time.millisecond.toString().padLeft(3, '0');
    return '$h:$mi:$s.$ms';
  }

  @override
  String toString() => '[$timeLabel ${level.name.toUpperCase()} $name] $message';
}

class LogsViewState {
  const LogsViewState({
    this.entries = const [],
    this.totalCount = 0,
    this.filterLevel,
    this.filterName,
    this.timeRange = LogsTimeRange.all,
    this.searchText = '',
    this.availableNames = const [],
  });

  final List<LogEntry> entries;
  final int totalCount;
  final LogLevel? filterLevel;
  final String? filterName;
  final LogsTimeRange timeRange;
  final String searchText;
  final List<String> availableNames;
}
