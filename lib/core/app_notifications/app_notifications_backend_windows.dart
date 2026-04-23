import 'package:flutter/services.dart';
import 'package:sgtp_flutter/core/app_notifications/app_notifications_backend.dart';
import 'package:sgtp_flutter/core/app_notifications/app_notification_models.dart';

class WindowsAppNotificationsBackend implements AppNotificationsBackend {
  WindowsAppNotificationsBackend() {
    _channel.setMethodCallHandler(_handleMethodCall);
  }

  static const MethodChannel _channel = MethodChannel(
    'com.example.sgtp_flutter/app_notifications',
  );
  AppNotificationEventListener? _eventListener;

  @override
  void setEventListener(AppNotificationEventListener? listener) {
    _eventListener = listener;
  }

  @override
  Future<void> show(String id, AppNotificationRequest request) {
    return _channel.invokeMethod<void>('showNotification', <String, Object?>{
      'id': id,
      'title': request.title,
      'subtitle': request.subtitle,
      'durationMs': request.duration.inMilliseconds,
      'imageBytes': request.imageBytes,
      'buttons': request.buttons
          .map(
            (button) => <String, Object?>{
              'label': button.label,
              'color': switch (button.color) {
                AppNotificationButtonColor.defaultColor => 'default',
                AppNotificationButtonColor.red => 'red',
              },
            },
          )
          .toList(growable: false),
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

  Future<void> _handleMethodCall(MethodCall call) async {
    final listener = _eventListener;
    if (listener == null) {
      return;
    }
    final arguments = call.arguments;
    if (arguments is! Map<Object?, Object?>) {
      return;
    }
    final id = arguments['id'];
    if (id is! String || id.isEmpty) {
      return;
    }
    switch (call.method) {
      case 'notificationActionInvoked':
        final buttonIndex = arguments['buttonIndex'];
        if (buttonIndex is int) {
          await listener(
            AppNotificationEvent.actionInvoked(
              id: id,
              buttonIndex: buttonIndex,
            ),
          );
        }
        break;
      case 'notificationDismissed':
        await listener(AppNotificationEvent.dismissed(id: id));
        break;
    }
  }
}
