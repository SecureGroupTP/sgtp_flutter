import 'package:flutter_test/flutter_test.dart';
import 'package:sgtp_flutter/features/notifications/application/services/notification_host_service.dart';
import 'package:sgtp_flutter/features/notifications/domain/entities/notification_host_status.dart';
import 'package:sgtp_flutter/features/notifications/domain/repositories/notification_host_platform_adapter.dart';

void main() {
  group('NotificationHostService', () {
    test('initializes host only once', () async {
      final adapter = _FakeNotificationHostPlatformAdapter();
      final service = NotificationHostService(platformAdapter: adapter);

      final first = await service.ensureInitialized();
      final second = await service.ensureInitialized();

      expect(first, NotificationHostStatus.supported);
      expect(second, NotificationHostStatus.supported);
      expect(adapter.initializeCalls, 1);
    });

    test('delegates start and stop once initialized', () async {
      final adapter = _FakeNotificationHostPlatformAdapter();
      final service = NotificationHostService(platformAdapter: adapter);

      await service.ensureInitialized();
      await service.activateAccount('acc-1');
      await service.stop();

      expect(adapter.startCalls, 1);
      expect(adapter.stopCalls, 1);
    });

    test('does not start unsupported notification host', () async {
      final adapter = _FakeNotificationHostPlatformAdapter(
        status: NotificationHostStatus.unsupported,
      );
      final service = NotificationHostService(platformAdapter: adapter);

      await service.activateAccount('acc-1');

      expect(adapter.initializeCalls, 1);
      expect(adapter.startCalls, 0);
    });

    test('disabled host stops legacy service and never starts', () async {
      final adapter = _FakeNotificationHostPlatformAdapter();
      final service = NotificationHostService(
        platformAdapter: adapter,
        enabled: false,
      );

      final status = await service.ensureInitialized();
      await service.activateAccount('acc-1');
      await service.start();

      expect(status, NotificationHostStatus.unsupported);
      expect(adapter.initializeCalls, 1);
      expect(adapter.stopCalls, 1);
      expect(adapter.startCalls, 0);
    });
  });
}

class _FakeNotificationHostPlatformAdapter
    implements NotificationHostPlatformAdapter {
  _FakeNotificationHostPlatformAdapter({
    this.status = NotificationHostStatus.supported,
  });

  final NotificationHostStatus status;
  int initializeCalls = 0;
  int startCalls = 0;
  int stopCalls = 0;

  @override
  Future<NotificationHostStatus> initialize() async {
    initializeCalls += 1;
    return status;
  }

  @override
  Future<bool> isRunning() async => startCalls > stopCalls;

  @override
  Future<void> startForAccount(String accountId) async {
    startCalls += 1;
  }

  @override
  Future<void> stop() async {
    stopCalls += 1;
  }

  @override
  Future<void> stopForAccount(String accountId) async {}
}
