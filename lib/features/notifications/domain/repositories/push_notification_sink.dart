import 'package:sgtp_flutter/features/notifications/domain/entities/notification_event.dart';

abstract class PushNotificationSink {
  Future<void> showMessage(NotificationEvent event);

  Future<void> showFriendRequest(NotificationEvent event);
}
