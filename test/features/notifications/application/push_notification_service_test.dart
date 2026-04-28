import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sgtp_flutter/features/notifications/application/services/push_notification_service.dart';
import 'package:sgtp_flutter/features/notifications/domain/repositories/push_device_registry.dart';
import 'package:sgtp_flutter/features/notifications/domain/repositories/push_messaging_client.dart';
import 'package:sgtp_flutter/features/notifications/domain/repositories/push_token_registrar.dart';

void main() {
  group('PushNotificationService', () {
    test(
      'does not register token before explicit profile-ready sync',
      () async {
        final messagingClient = _FakeMessagingClient(initialToken: 'token-1');
        final registrar = _FakeRegistrar();
        final service = PushNotificationService(
          messagingClient: messagingClient,
          deviceRegistry: _FakeRegistry(deviceId: 'device-1'),
          tokenRegistrar: registrar,
          platformCode: 1,
        );

        await service.activateAccount('acc-1');
        messagingClient.emitTokenRefresh('token-2');
        await Future<void>.delayed(Duration.zero);

        expect(registrar.calls, isEmpty);
      },
    );

    test(
      'registers active account token after profile-ready sync and refreshes',
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
        await service.syncRegistration();

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

    test(
      'keeps explicit sync non-fatal when server still requires profile',
      () async {
        final messagingClient = _FakeMessagingClient(initialToken: 'token-1');
        final registrar = _FakeRegistrar(
          error: StateError(
            'profile_required: profile must be completed before using this RPC',
          ),
        );
        final service = PushNotificationService(
          messagingClient: messagingClient,
          deviceRegistry: _FakeRegistry(deviceId: 'device-1'),
          tokenRegistrar: registrar,
          platformCode: 1,
        );

        await service.activateAccount('acc-1');
        await service.syncRegistration();

        expect(registrar.calls, hasLength(1));

        messagingClient.emitTokenRefresh('token-2');
        await Future<void>.delayed(Duration.zero);

        expect(registrar.calls, hasLength(1));
      },
    );

    test('does not register token for unsupported platform code', () async {
      final messagingClient = _FakeMessagingClient(initialToken: 'token-1');
      final registrar = _FakeRegistrar();
      final service = PushNotificationService(
        messagingClient: messagingClient,
        deviceRegistry: _FakeRegistry(deviceId: 'device-1'),
        tokenRegistrar: registrar,
        platformCode: 0,
      );

      await service.activateAccount('acc-1');
      await service.syncRegistration();
      messagingClient.emitTokenRefresh('token-2');
      await Future<void>.delayed(Duration.zero);

      expect(registrar.calls, isEmpty);
    });

    test('keeps sync non-fatal when messaging token lookup fails', () async {
      final messagingClient = _FakeMessagingClient(
        tokenError: StateError('firebase unavailable'),
      );
      final registrar = _FakeRegistrar();
      final service = PushNotificationService(
        messagingClient: messagingClient,
        deviceRegistry: _FakeRegistry(deviceId: 'device-1'),
        tokenRegistrar: registrar,
        platformCode: 1,
      );

      await service.activateAccount('acc-1');
      await service.syncRegistration();

      expect(registrar.calls, isEmpty);
    });
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
  _FakeMessagingClient({this.initialToken, this.tokenError});

  final String? initialToken;
  final Object? tokenError;
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
  Future<String?> getToken() async {
    final error = tokenError;
    if (error != null) throw error;
    return initialToken;
  }

  @override
  Future<void> initialize() async {
    initialized = true;
  }

  @override
  Future<bool> requestPermission() async => true;
}

class _FakeRegistrar implements PushTokenRegistrar {
  _FakeRegistrar({this.error});

  final Object? error;
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
    final error = this.error;
    if (error != null) throw error;
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
