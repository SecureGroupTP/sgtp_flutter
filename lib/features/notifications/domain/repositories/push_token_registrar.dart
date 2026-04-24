abstract class PushTokenRegistrar {
  Future<void> registerToken({
    required String accountId,
    required String deviceId,
    required int platformCode,
    required String pushToken,
    required bool isEnabled,
  });
}
