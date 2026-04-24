import 'package:flutter_test/flutter_test.dart';
import 'package:sgtp_flutter/features/notifications/application/services/notification_host_service.dart';
import 'package:sgtp_flutter/features/notifications/domain/entities/notification_host_status.dart';
import 'package:sgtp_flutter/features/notifications/domain/repositories/notification_host_platform_adapter.dart';

void main() {
  test('host service tracks active account and ignores duplicate start', () async {
    final adapter = _RecordingHostAdapter();
    final service = NotificationHostService(platformAdapter: adapter);

    await service.activateAccount('acc-1');
    await service.activateAccount('acc-1');
    await service.activateAccount('acc-2');
    await service.deactivateAccount('acc-1');
    await service.deactivateAccount('acc-2');

    expect(adapter.startedAccounts, <String>['acc-1', 'acc-2']);
    expect(adapter.stoppedAccounts, <String>['acc-1', 'acc-2']);
  });
}

class _RecordingHostAdapter implements NotificationHostPlatformAdapter {
  final List<String> startedAccounts = <String>[];
  final List<String> stoppedAccounts = <String>[];

  @override
  Future<NotificationHostStatus> initialize() async =>
      NotificationHostStatus.supported;

  @override
  Future<bool> isRunning() async => startedAccounts.length > stoppedAccounts.length;

  @override
  Future<void> startForAccount(String accountId) async {
    startedAccounts.add(accountId);
  }

  @override
  Future<void> stop() async {}

  @override
  Future<void> stopForAccount(String accountId) async {
    stoppedAccounts.add(accountId);
  }
}
