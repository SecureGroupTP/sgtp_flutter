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

Map<String, dynamic> _mapValue(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) {
    return value.map((key, item) => MapEntry('$key', item));
  }
  return const {};
}
