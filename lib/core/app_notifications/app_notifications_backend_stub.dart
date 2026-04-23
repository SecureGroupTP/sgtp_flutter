import 'package:sgtp_flutter/core/app_notifications/app_notifications_backend.dart';
import 'package:sgtp_flutter/core/app_notifications/app_notification_models.dart';

AppNotificationsBackend createAppNotificationsBackend() =>
    const UnsupportedAppNotificationsBackend();

class UnsupportedAppNotificationsBackend implements AppNotificationsBackend {
  const UnsupportedAppNotificationsBackend();

  @override
  void setEventListener(AppNotificationEventListener? listener) {}

  @override
  Future<void> dismiss(String id) async {}

  @override
  Future<void> dismissAll() async {}

  @override
  Future<void> show(String id, AppNotificationRequest request) async {}

  @override
  bool supports(AppNotificationRequest request) => false;
}
