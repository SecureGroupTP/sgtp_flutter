import 'package:sgtp_flutter/core/network/rpc_models/device_rpc_models.dart';
import 'package:sgtp_flutter/core/network/sgtp_connection_service.dart';
import 'package:sgtp_flutter/features/notifications/domain/repositories/push_token_registrar.dart';

class SgtpPushTokenRegistrar implements PushTokenRegistrar {
  SgtpPushTokenRegistrar({required SgtpConnectionService connectionService})
    : _connectionService = connectionService;

  final SgtpConnectionService _connectionService;

  @override
  Future<void> registerToken({
    required String accountId,
    required String deviceId,
    required int platformCode,
    required String pushToken,
    required bool isEnabled,
  }) async {
    final rpc = await _connectionService.ensureConnected();
    await rpc.callRpc(
      RegisterDevicePushTokenRequest(
        platform: platformCode,
        pushToken: pushToken,
        isEnabled: isEnabled,
      ),
    );
  }
}
