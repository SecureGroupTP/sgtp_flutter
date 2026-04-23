import 'package:sgtp_flutter/core/app_notifications/app_notification_models.dart';

typedef AppNotificationEventListener =
    Future<void> Function(AppNotificationEvent event);

abstract class AppNotificationsBackend {
  void setEventListener(AppNotificationEventListener? listener);

  Future<void> show(String id, AppNotificationRequest request);

  Future<void> dismiss(String id);

  Future<void> dismissAll();

  bool supports(AppNotificationRequest request);
}
