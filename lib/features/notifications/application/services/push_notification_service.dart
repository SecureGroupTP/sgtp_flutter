import 'dart:async';

import 'package:sgtp_flutter/features/notifications/application/services/push_message_processor.dart';
import 'package:sgtp_flutter/features/notifications/domain/repositories/push_device_registry.dart';
import 'package:sgtp_flutter/features/notifications/domain/repositories/push_messaging_client.dart';
import 'package:sgtp_flutter/features/notifications/domain/repositories/push_token_registrar.dart';

class PushNotificationService {
  PushNotificationService({
    required PushMessagingClient messagingClient,
    required PushDeviceRegistry deviceRegistry,
    required PushTokenRegistrar tokenRegistrar,
    PushMessageProcessor? messageProcessor,
    required int platformCode,
  }) : _messagingClient = messagingClient,
       _deviceRegistry = deviceRegistry,
       _tokenRegistrar = tokenRegistrar,
       _messageProcessor = messageProcessor,
       _platformCode = platformCode;

  final PushMessagingClient _messagingClient;
  final PushDeviceRegistry _deviceRegistry;
  final PushTokenRegistrar _tokenRegistrar;
  final PushMessageProcessor? _messageProcessor;
  final int _platformCode;

  bool _initialized = false;
  String? _activeAccountId;
  StreamSubscription<String>? _tokenRefreshSub;
  StreamSubscription<Map<String, String>>? _foregroundMessagesSub;

  Future<void> ensureInitialized() async {
    if (_initialized) {
      return;
    }
    await _messagingClient.initialize();
    await _messagingClient.requestPermission();
    _tokenRefreshSub = _messagingClient.onTokenRefresh.listen((token) {
      unawaited(_registerToken(token));
    });
    final processor = _messageProcessor;
    if (processor != null) {
      _foregroundMessagesSub = _messagingClient.onForegroundMessage.listen((
        data,
      ) {
        unawaited(processor.process(data));
      });
    }
    _initialized = true;
  }

  Future<void> activateAccount(String accountId) async {
    final normalized = accountId.trim();
    _activeAccountId = normalized.isEmpty ? null : normalized;
    await syncRegistration();
  }

  Future<void> deactivateAccount(String accountId) async {
    final normalized = accountId.trim();
    if (normalized.isEmpty || normalized != _activeAccountId) {
      return;
    }
    _activeAccountId = null;
  }

  Future<void> syncRegistration() async {
    await ensureInitialized();
    final token = await _messagingClient.getToken();
    if (token == null || token.trim().isEmpty) {
      return;
    }
    await _registerToken(token);
  }

  Future<void> dispose() async {
    await _tokenRefreshSub?.cancel();
    await _foregroundMessagesSub?.cancel();
    _tokenRefreshSub = null;
    _foregroundMessagesSub = null;
  }

  Future<void> _registerToken(String rawToken) async {
    final accountId = _activeAccountId;
    final token = rawToken.trim();
    if (accountId == null || accountId.isEmpty || token.isEmpty) {
      return;
    }
    final deviceId = await _deviceRegistry.loadDeviceId(accountId);
    await _tokenRegistrar.registerToken(
      accountId: accountId,
      deviceId: deviceId,
      platformCode: _platformCode,
      pushToken: token,
      isEnabled: true,
    );
  }
}
