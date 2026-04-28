import 'dart:async';

import 'package:sgtp_flutter/core/app_log.dart';
import 'package:sgtp_flutter/features/notifications/application/services/push_message_processor.dart';
import 'package:sgtp_flutter/features/notifications/domain/repositories/push_device_registry.dart';
import 'package:sgtp_flutter/features/notifications/domain/repositories/push_messaging_client.dart';
import 'package:sgtp_flutter/features/notifications/domain/repositories/push_token_registrar.dart';

final _log = AppLog('PushNotificationService');

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
  bool _registrationEnabled = false;
  StreamSubscription<String>? _tokenRefreshSub;
  StreamSubscription<Map<String, String>>? _foregroundMessagesSub;

  Future<void> ensureInitialized() async {
    if (_initialized) {
      return;
    }
    await _messagingClient.initialize();
    await _messagingClient.requestPermission();

    _tokenRefreshSub = _messagingClient.onTokenRefresh.listen((token) {
      if (!_registrationEnabled) return;
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
    _registrationEnabled = false;
    await ensureInitialized();
  }

  Future<void> deactivateAccount(String accountId) async {
    final normalized = accountId.trim();
    if (normalized.isEmpty || normalized != _activeAccountId) {
      return;
    }
    _activeAccountId = null;
    _registrationEnabled = false;
  }

  Future<void> syncRegistration() async {
    _registrationEnabled = true;
    await ensureInitialized();

    if (_platformCode <= 0) {
      _log.debug('Push token registration skipped: unsupported platform');
      return;
    }

    final String? token;
    try {
      token = await _messagingClient.getToken();
    } catch (e, st) {
      _log.warning(
        'Push token lookup failed: {error}',
        parameters: {'error': e},
        error: e,
        stackTrace: st,
      );
      return;
    }
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

    if (accountId == null ||
        accountId.isEmpty ||
        token.isEmpty ||
        _platformCode <= 0) {
      return;
    }

    final deviceId = await _deviceRegistry.loadDeviceId(accountId);

    try {
      await _tokenRegistrar.registerToken(
        accountId: accountId,
        deviceId: deviceId,
        platformCode: _platformCode,
        pushToken: token,
        isEnabled: true,
      );
    } on StateError catch (e) {
      if (!_isProfileRequiredError(e)) rethrow;
      _registrationEnabled = false;
    }
  }

  bool _isProfileRequiredError(StateError error) {
    return error.message.startsWith('profile_required:');
  }
}
