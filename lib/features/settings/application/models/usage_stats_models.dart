class UsageStat {
  final int requests;
  final int bytesIn;
  final int bytesOut;

  const UsageStat({
    required this.requests,
    required this.bytesIn,
    required this.bytesOut,
  });
}

class UsageStatsSummary {
  final UsageStat minute;
  final UsageStat hour;
  final UsageStat day;
  final UsageStat week;
  final UsageStat month;
  final UsageStat allTime;

  const UsageStatsSummary({
    required this.minute,
    required this.hour,
    required this.day,
    required this.week,
    required this.month,
    required this.allTime,
  });
}

