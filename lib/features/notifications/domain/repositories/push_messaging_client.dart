abstract class PushMessagingClient {
  Future<void> initialize();

  Future<bool> requestPermission();

  Future<String?> getToken();

  Stream<String> get onTokenRefresh;

  Stream<Map<String, String>> get onForegroundMessage;
}
