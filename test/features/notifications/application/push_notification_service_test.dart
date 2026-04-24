import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sgtp_flutter/features/notifications/application/services/push_notification_service.dart';
import 'package:sgtp_flutter/features/notifications/domain/repositories/push_device_registry.dart';
import 'package:sgtp_flutter/features/notifications/domain/repositories/push_messaging_client.dart';
import 'package:sgtp_flutter/features/notifications/domain/repositories/push_token_registrar.dart';

void main() {
  group('PushNotificationService', () {
    test(
      'registers active account token and refreshes on token updates',
      () async {
        final messagingClient = _FakeMessagingClient(initialToken: 'token-1');
        final registrar = _FakeRegistrar();
        final service = PushNotificationService(
          messagingClient: messagingClient,
          deviceRegistry: _FakeRegistry(deviceId: 'device-1'),
          tokenRegistrar: registrar,
          platformCode: 1,
        );

        await service.ensureInitialized();
        await service.activateAccount('acc-1');

        expect(registrar.calls, hasLength(1));
        expect(registrar.calls.single.accountId, 'acc-1');
        expect(registrar.calls.single.deviceId, 'device-1');
        expect(registrar.calls.single.token, 'token-1');

        messagingClient.emitTokenRefresh('token-2');
        await Future<void>.delayed(Duration.zero);

        expect(registrar.calls, hasLength(2));
        expect(registrar.calls.last.token, 'token-2');
      },
    );
  });
}

class _FakeRegistry implements PushDeviceRegistry {
  _FakeRegistry({required this.deviceId});

  final String deviceId;

  @override
  Future<String> loadDeviceId(String accountId) async => deviceId;

  @override
  Future<String?> resolveAccountId({
    String? accountId,
    String? deviceId,
  }) async {
    throw UnimplementedError();
  }
}

class _FakeMessagingClient implements PushMessagingClient {
  _FakeMessagingClient({this.initialToken});

  final String? initialToken;
  final StreamController<String> _tokenRefreshController =
      StreamController<String>.broadcast();
  bool initialized = false;

  @override
  Stream<Map<String, String>> get onForegroundMessage =>
      const Stream<Map<String, String>>.empty();

  @override
  Stream<String> get onTokenRefresh => _tokenRefreshController.stream;

  void emitTokenRefresh(String token) {
    _tokenRefreshController.add(token);
  }

  @override
  Future<String?> getToken() async => initialToken;

  @override
  Future<void> initialize() async {
    initialized = true;
  }

  @override
  Future<bool> requestPermission() async => true;
}

class _FakeRegistrar implements PushTokenRegistrar {
  final List<_RegisterCall> calls = <_RegisterCall>[];

  @override
  Future<void> registerToken({
    required String accountId,
    required String deviceId,
    required int platformCode,
    required String pushToken,
    required bool isEnabled,
  }) async {
    calls.add(
      _RegisterCall(
        accountId: accountId,
        deviceId: deviceId,
        platformCode: platformCode,
        token: pushToken,
        isEnabled: isEnabled,
      ),
    );
  }
}

class _RegisterCall {
  const _RegisterCall({
    required this.accountId,
    required this.deviceId,
    required this.platformCode,
    required this.token,
    required this.isEnabled,
  });

  final String accountId;
  final String deviceId;
  final int platformCode;
  final String token;
  final bool isEnabled;
}
