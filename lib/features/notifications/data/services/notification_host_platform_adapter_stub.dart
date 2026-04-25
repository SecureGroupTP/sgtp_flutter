import 'package:sgtp_flutter/features/notifications/domain/entities/notification_host_status.dart';
import 'package:sgtp_flutter/features/notifications/domain/repositories/notification_host_platform_adapter.dart';

NotificationHostPlatformAdapter createNotificationHostPlatformAdapterImpl() =>
    _UnsupportedNotificationHostPlatformAdapter();

class _UnsupportedNotificationHostPlatformAdapter
    implements NotificationHostPlatformAdapter {
  @override
  Future<NotificationHostStatus> initialize() async =>
      NotificationHostStatus.unsupported;

  @override
  Future<bool> isRunning() async => false;

  @override
  Future<void> startForAccount(String accountId) async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> stopForAccount(String accountId) async {}
}
