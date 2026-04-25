// ignore_for_file: avoid_web_libraries_in_flutter

import 'dart:async';
import 'dart:html' as html;

import 'package:sgtp_flutter/core/app_notifications/app_notification_models.dart';
import 'package:sgtp_flutter/core/app_notifications/app_notifications_backend.dart';

class WebAppNotificationsBackend implements AppNotificationsBackend {
  final Map<String, html.Notification> _active = <String, html.Notification>{};
  AppNotificationEventListener? _eventListener;

  @override
  void setEventListener(AppNotificationEventListener? listener) {
    _eventListener = listener;
  }

  @override
  Future<void> show(String id, AppNotificationRequest request) async {
    if (!supports(request)) {
      return;
    }
    if (!html.Notification.supported) {
      return;
    }
    final permission = html.Notification.permission;
    if (permission != 'granted') {
      return;
    }
    final iconUrl = request.imageBytes == null || request.imageBytes!.isEmpty
        ? null
        : Uri.dataFromBytes(
            request.imageBytes!,
            mimeType: 'image/png',
          ).toString();
    final notification = html.Notification(
      request.title ?? 'SGTP',
      body: request.subtitle,
      icon: iconUrl,
      tag: id,
    );
    notification.onClick.listen((_) {
      unawaited(_eventListener?.call(AppNotificationEvent.dismissed(id: id)));
      notification.close();
      _active.remove(id);
    });
    notification.onClose.listen((_) {
      _active.remove(id);
      unawaited(_eventListener?.call(AppNotificationEvent.dismissed(id: id)));
    });
    _active[id]?.close();
    _active[id] = notification;

    final worker = html.window.navigator.serviceWorker?.controller;
    worker?.postMessage(<String, Object?>{
      'type': 'showNotification',
      'id': id,
      'title': request.title,
      'subtitle': request.subtitle,
      'iconUrl': iconUrl,
      'buttons': request.buttons
          .map(
            (button) => <String, String>{
              'label': button.label,
              'color': button.color.name,
            },
          )
          .toList(growable: false),
    });
  }

  @override
  Future<void> dismiss(String id) async {
    _active.remove(id)?.close();
  }

  @override
  Future<void> dismissAll() async {
    final ids = _active.keys.toList(growable: false);
    for (final id in ids) {
      _active.remove(id)?.close();
    }
  }

  @override
  bool supports(AppNotificationRequest request) {
    return html.Notification.supported &&
        ((request.title != null && request.title!.trim().isNotEmpty) ||
            (request.subtitle != null && request.subtitle!.trim().isNotEmpty));
  }
}
