import 'package:sgtp_flutter/core/network/rpc_models/rpc_request.dart';

class ServerConfigData {
  final int updatedAtUs;
  final String version;

  const ServerConfigData({
    required this.updatedAtUs,
    required this.version,
  });

  static ServerConfigData fromMap(Map<String, dynamic> m) => ServerConfigData(
        updatedAtUs: parseTimestampUs(m['updatedAt']),
        version: m['version'] as String? ?? '',
      );
}

class GetServerLimitsRequest extends RpcRequest {
  const GetServerLimitsRequest();

  @override
  String get method => 'getServerLimits';

  @override
  Map<String, dynamic> toMap() => const {};
}

class GetServerLimitsResponse {
  final Map<String, dynamic> limits;
  final Map<String, dynamic> spent;

  const GetServerLimitsResponse({
    required this.limits,
    required this.spent,
  });

  static GetServerLimitsResponse fromMap(Map<String, dynamic> m) =>
      GetServerLimitsResponse(
        limits: _mapValue(m['limits']),
        spent: _mapValue(m['spent']),
      );
}

class GetServerConfigRequest extends RpcRequest {
  const GetServerConfigRequest();

  @override
  String get method => 'getServerConfig';

  @override
  Map<String, dynamic> toMap() => const {};
}

class GetServerConfigResponse {
  final ServerConfigData config;

  const GetServerConfigResponse({required this.config});

  static GetServerConfigResponse fromMap(Map<String, dynamic> m) =>
      GetServerConfigResponse(
        config: ServerConfigData.fromMap(_mapValue(m['config'])),
      );
}

class GetUserLimitsRequest extends RpcRequest {
  const GetUserLimitsRequest();

  @override
  String get method => 'getUserLimits';

  @override
  Map<String, dynamic> toMap() => const {};
}

class GetUserLimitsResponse {
  final Map<String, dynamic> limits;
  final Map<String, dynamic> spent;

  const GetUserLimitsResponse({
    required this.limits,
    required this.spent,
  });

  static GetUserLimitsResponse fromMap(Map<String, dynamic> m) =>
      GetUserLimitsResponse(
        limits: _mapValue(m['limits']),
        spent: _mapValue(m['spent']),
      );
}

class GetGroupLimitsRequest extends RpcRequest {
  final String roomId;

  const GetGroupLimitsRequest({required this.roomId});

  @override
  String get method => 'getGroupLimits';

  @override
  Map<String, dynamic> toMap() => {'roomId': roomId};
}

class GetGroupLimitsResponse {
  final Map<String, dynamic> limits;
  final Map<String, dynamic> spent;

  const GetGroupLimitsResponse({
    required this.limits,
    required this.spent,
  });

  static GetGroupLimitsResponse fromMap(Map<String, dynamic> m) =>
      GetGroupLimitsResponse(
        limits: _mapValue(m['limits']),
        spent: _mapValue(m['spent']),
      );
}

class UsageStatData {
  final int requests;
  final int bytesIn;
  final int bytesOut;

  const UsageStatData({
    required this.requests,
    required this.bytesIn,
    required this.bytesOut,
  });

  static UsageStatData fromMap(Map<String, dynamic> m) => UsageStatData(
        requests: (m['requests'] as num?)?.toInt() ?? 0,
        bytesIn: (m['bytesIn'] as num?)?.toInt() ?? 0,
        bytesOut: (m['bytesOut'] as num?)?.toInt() ?? 0,
      );
}

class GetMyUsageStatsRequest extends RpcRequest {
  const GetMyUsageStatsRequest();

  @override
  String get method => 'getMyUsageStats';

  @override
  Map<String, dynamic> toMap() => const {};
}

class GetMyUsageStatsResponse {
  final UsageStatData minute;
  final UsageStatData hour;
  final UsageStatData day;
  final UsageStatData week;
  final UsageStatData month;
  final UsageStatData allTime;

  const GetMyUsageStatsResponse({
    required this.minute,
    required this.hour,
    required this.day,
    required this.week,
    required this.month,
    required this.allTime,
  });

  static GetMyUsageStatsResponse fromMap(Map<String, dynamic> m) =>
      GetMyUsageStatsResponse(
        minute: UsageStatData.fromMap(_mapValue(m['minute'])),
        hour: UsageStatData.fromMap(_mapValue(m['hour'])),
        day: UsageStatData.fromMap(_mapValue(m['day'])),
        week: UsageStatData.fromMap(_mapValue(m['week'])),
        month: UsageStatData.fromMap(_mapValue(m['month'])),
        allTime: UsageStatData.fromMap(_mapValue(m['allTime'])),
      );
}

Map<String, dynamic> _mapValue(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) {
    return value.map((key, item) => MapEntry('$key', item));
  }
  return const {};
}
