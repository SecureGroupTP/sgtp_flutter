import 'package:sgtp_flutter/features/notifications/domain/entities/notification_host_status.dart';

abstract class NotificationHostPlatformAdapter {
  Future<NotificationHostStatus> initialize();

  Future<void> startForAccount(String accountId);

  Future<void> stop();

  Future<void> stopForAccount(String accountId);

  Future<bool> isRunning();
}
