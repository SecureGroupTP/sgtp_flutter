import 'package:sgtp_flutter/core/app_notifications/app_notification_models.dart';

abstract class AppNotificationsBackend {
  Future<void> show(String id, AppNotificationRequest request);

  Future<void> dismiss(String id);

  Future<void> dismissAll();

  bool supports(AppNotificationRequest request);
}
