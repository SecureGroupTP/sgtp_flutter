import 'package:flutter/services.dart';
import 'package:sgtp_flutter/core/app_notifications/app_notifications_backend.dart';
import 'package:sgtp_flutter/core/app_notifications/app_notification_models.dart';

class WindowsAppNotificationsBackend implements AppNotificationsBackend {
  WindowsAppNotificationsBackend();

  static const MethodChannel _channel = MethodChannel(
    'com.example.sgtp_flutter/app_notifications',
  );

  @override
  Future<void> show(String id, AppNotificationRequest request) {
    return _channel.invokeMethod<void>('showNotification', <String, Object?>{
      'id': id,
      'title': request.title,
      'subtitle': request.subtitle,
      'durationMs': request.duration.inMilliseconds,
      'imageBytes': request.imageBytes,
    });
  }

  @override
  Future<void> dismiss(String id) {
    return _channel.invokeMethod<void>('dismissNotification', <String, Object?>{
      'id': id,
    });
  }

  @override
  Future<void> dismissAll() {
    return _channel.invokeMethod<void>('dismissAllNotifications');
  }

  @override
  bool supports(AppNotificationRequest request) {
    return (request.title != null && request.title!.isNotEmpty) ||
        (request.subtitle != null && request.subtitle!.isNotEmpty) ||
        (request.imageBytes != null && request.imageBytes!.isNotEmpty);
  }
}
