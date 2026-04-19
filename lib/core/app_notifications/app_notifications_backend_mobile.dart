import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:sgtp_flutter/core/app_notifications/app_notifications_backend.dart';
import 'package:sgtp_flutter/core/app_notifications/app_notification_models.dart';

class MobileAppNotificationsBackend implements AppNotificationsBackend {
  MobileAppNotificationsBackend();

  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  bool _initialized = false;

  @override
  Future<void> show(String id, AppNotificationRequest request) async {
    await _ensureInitialized();
    await _plugin.show(
      _notificationIntId(id),
      request.title,
      request.subtitle,
      NotificationDetails(
        android: _buildAndroidDetails(request),
        iOS: await _buildDarwinDetails(id, request),
      ),
      payload: id,
    );
  }

  @override
  Future<void> dismiss(String id) async {
    await _ensureInitialized();
    await _plugin.cancel(_notificationIntId(id));
  }

  @override
  Future<void> dismissAll() async {
    await _ensureInitialized();
    await _plugin.cancelAll();
  }

  @override
  bool supports(AppNotificationRequest request) {
    return (request.title != null && request.title!.isNotEmpty) ||
        (request.subtitle != null && request.subtitle!.isNotEmpty) ||
        (request.imageBytes != null && request.imageBytes!.isNotEmpty);
  }

  Future<void> _ensureInitialized() async {
    if (_initialized) {
      return;
    }

    const androidSettings =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    const darwinSettings = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );

    await _plugin.initialize(
      const InitializationSettings(
        android: androidSettings,
        iOS: darwinSettings,
      ),
    );

    if (Platform.isAndroid) {
      await _plugin
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();
    }

    _initialized = true;
  }

  AndroidNotificationDetails _buildAndroidDetails(
    AppNotificationRequest request,
  ) {
    final subtitle = request.subtitle ?? '';
    if (request.imageBytes != null && request.imageBytes!.isNotEmpty) {
      final largeIcon =
          ByteArrayAndroidBitmap.fromBase64String(
              base64Encode(request.imageBytes!));
      return AndroidNotificationDetails(
        'sgtp_app_notifications',
        'App Notifications',
        channelDescription: 'General SGTP app notifications',
        importance: Importance.high,
        priority: Priority.high,
        largeIcon: largeIcon,
        styleInformation: BigTextStyleInformation(subtitle),
        timeoutAfter: request.duration.inMilliseconds,
      );
    }
    return AndroidNotificationDetails(
      'sgtp_app_notifications',
      'App Notifications',
      channelDescription: 'General SGTP app notifications',
      importance: Importance.high,
      priority: Priority.high,
      styleInformation: BigTextStyleInformation(subtitle),
      timeoutAfter: request.duration.inMilliseconds,
    );
  }

  Future<DarwinNotificationDetails> _buildDarwinDetails(
    String id,
    AppNotificationRequest request,
  ) async {
    if (!Platform.isIOS ||
        request.imageBytes == null ||
        request.imageBytes!.isEmpty) {
      return const DarwinNotificationDetails();
    }
    try {
      final path = await _writeTmpAttachment(id, request.imageBytes!);
      return DarwinNotificationDetails(
        attachments: [DarwinNotificationAttachment(path)],
      );
    } catch (_) {
      return const DarwinNotificationDetails();
    }
  }

  int _notificationIntId(String id) => id.hashCode & 0x7FFFFFFF;

  static Future<String> _writeTmpAttachment(String id, Uint8List bytes) async {
    final file = File(
      '${Directory.systemTemp.path}/sgtp_app_notif_${id.hashCode & 0x7FFFFFFF}.jpg',
    );
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }
}
