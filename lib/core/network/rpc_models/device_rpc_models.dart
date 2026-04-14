import 'package:sgtp_flutter/core/network/rpc_models/rpc_request.dart';

class ListDevicesRequest extends RpcRequest {
  const ListDevicesRequest();

  @override
  String get method => 'listDevices';

  @override
  Map<String, dynamic> toMap() => const {};
}

class DeviceItem {
  final String deviceId;
  final int platform;
  final String pushToken;
  final bool isEnabled;
  final int updatedAtUs;

  const DeviceItem({
    required this.deviceId,
    required this.platform,
    required this.pushToken,
    required this.isEnabled,
    required this.updatedAtUs,
  });

  static DeviceItem fromMap(Map<String, dynamic> m) => DeviceItem(
        deviceId: _uuidToString(m['deviceId']),
        platform: (m['platform'] as num?)?.toInt() ?? 0,
        pushToken: m['pushToken'] as String? ?? '',
        isEnabled: (m['isEnabled'] as bool?) ?? false,
        updatedAtUs: parseTimestampUs(m['updatedAt']),
      );
}

class ListDevicesResponse {
  final List<DeviceItem> items;

  const ListDevicesResponse({required this.items});

  static ListDevicesResponse fromMap(Map<String, dynamic> m) {
    final rawItems = (m['items'] as List?) ?? const [];
    return ListDevicesResponse(
      items: rawItems
          .whereType<Map>()
          .map((item) => DeviceItem.fromMap(
              item.map((key, value) => MapEntry('$key', value))))
          .toList(),
    );
  }
}

class RegisterDevicePushTokenRequest extends RpcRequest {
  final int platform;
  final String pushToken;
  final bool isEnabled;

  const RegisterDevicePushTokenRequest({
    required this.platform,
    required this.pushToken,
    required this.isEnabled,
  });

  @override
  String get method => 'registerDevicePushToken';

  @override
  Map<String, dynamic> toMap() => {
        'platform': platform,
        'pushToken': pushToken,
        'isEnabled': isEnabled,
      };
}

class RegisterDevicePushTokenResponse {
  final String id;
  final int updatedAtUs;

  const RegisterDevicePushTokenResponse({
    required this.id,
    required this.updatedAtUs,
  });

  static RegisterDevicePushTokenResponse fromMap(Map<String, dynamic> m) =>
      RegisterDevicePushTokenResponse(
        id: _uuidToString(m['id']),
        updatedAtUs: parseTimestampUs(m['updatedAt']),
      );
}

class RemoveDeviceRequest extends RpcRequest {
  final String deviceId;

  const RemoveDeviceRequest({required this.deviceId});

  @override
  String get method => 'removeDevice';

  @override
  Map<String, dynamic> toMap() => {'deviceId': deviceId};
}

class RemoveDeviceResponse {
  final int removedAtUs;

  const RemoveDeviceResponse({required this.removedAtUs});

  static RemoveDeviceResponse fromMap(Map<String, dynamic> m) =>
      RemoveDeviceResponse(
        removedAtUs: parseTimestampUs(m['removedAt']),
      );
}

String _uuidToString(Object? value) {
  if (value is String) return value;
  if (value is List<int>) {
    return value.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
  return '';
}
