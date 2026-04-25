import 'package:sgtp_flutter/features/notifications/domain/entities/notification_host_status.dart';
import 'package:sgtp_flutter/features/notifications/domain/repositories/notification_host_platform_adapter.dart';

class WindowsNotificationHostPlatformAdapter
    implements NotificationHostPlatformAdapter {
  @override
  Future<NotificationHostStatus> initialize() async =>
      NotificationHostStatus.supported;

  @override
  Future<bool> isRunning() async => true;

  @override
  Future<void> startForAccount(String accountId) async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> stopForAccount(String accountId) async {}
}
