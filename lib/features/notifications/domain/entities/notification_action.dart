import 'dart:async';

import 'package:sgtp_flutter/core/app_notifications/app_notification_models.dart';

typedef NotificationActionCallback = FutureOr<void> Function();

class NotificationAction {
  const NotificationAction({
    required this.label,
    required this.onInvoked,
    this.color = AppNotificationButtonColor.defaultColor,
  });

  final String label;
  final AppNotificationButtonColor color;
  final NotificationActionCallback onInvoked;
}
