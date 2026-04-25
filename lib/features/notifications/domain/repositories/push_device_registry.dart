abstract class PushDeviceRegistry {
  Future<String> loadDeviceId(String accountId);

  Future<String?> resolveAccountId({String? accountId, String? deviceId});
}
