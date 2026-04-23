import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:sgtp_flutter/core/app_notifications/app_notifications_backend.dart';
import 'package:sgtp_flutter/core/app_notifications/app_notification_models.dart';

class MobileAppNotificationsBackend implements AppNotificationsBackend {
  MobileAppNotificationsBackend();

  static const String _actionIdPrefix = 'app_notification_action_';
  static const String _darwinCategoryPrefix = 'app_notification_category_';

  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  bool _initialized = false;
  AppNotificationEventListener? _eventListener;
  final Map<String, DarwinNotificationCategory> _darwinCategories =
      <String, DarwinNotificationCategory>{};

  @override
  void setEventListener(AppNotificationEventListener? listener) {
    _eventListener = listener;
  }

  @override
  Future<void> show(String id, AppNotificationRequest request) async {
    await _ensureInitialized(request: request);
    await _plugin.show(
      _notificationIntId(id),
      request.title,
      request.subtitle,
      NotificationDetails(
        android: _buildAndroidDetails(request),
        iOS: await _buildDarwinDetails(request),
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

  Future<void> _ensureInitialized({AppNotificationRequest? request}) async {
    final needsDarwinRefresh = _registerDarwinCategoryIfNeeded(request);
    if (_initialized && !needsDarwinRefresh) {
      return;
    }
    const androidSettings =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    final darwinSettings = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
      notificationCategories: _darwinCategories.values.toList(growable: false),
    );

    await _plugin.initialize(
      InitializationSettings(
        android: androidSettings,
        iOS: darwinSettings,
      ),
      onDidReceiveNotificationResponse: _onDidReceiveNotificationResponse,
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
    final actions = request.buttons
        .asMap()
        .entries
        .map(
          (entry) => AndroidNotificationAction(
            _actionId(entry.key),
            entry.value.label,
            titleColor: switch (entry.value.color) {
              AppNotificationButtonColor.defaultColor => null,
              AppNotificationButtonColor.red => const Color(0xFFFF6B6B),
            },
            cancelNotification: true,
          ),
        )
        .toList(growable: false);
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
        timeoutAfter: request.mobileDuration?.inMilliseconds,
        actions: actions,
      );
    }
    return AndroidNotificationDetails(
      'sgtp_app_notifications',
      'App Notifications',
      channelDescription: 'General SGTP app notifications',
      importance: Importance.high,
      priority: Priority.high,
      styleInformation: BigTextStyleInformation(subtitle),
      timeoutAfter: request.mobileDuration?.inMilliseconds,
      actions: actions,
    );
  }

  Future<DarwinNotificationDetails> _buildDarwinDetails(
    AppNotificationRequest request,
  ) async {
    final attachments = <DarwinNotificationAttachment>[];
    if (Platform.isIOS &&
        request.imageBytes != null &&
        request.imageBytes!.isNotEmpty) {
      try {
        final path = await _writeTmpAttachment(
          '${request.title ?? 'notif'}_${DateTime.now().microsecondsSinceEpoch}',
          request.imageBytes!,
        );
        attachments.add(DarwinNotificationAttachment(path));
      } catch (_) {}
    }
    final categoryIdentifier = _darwinCategoryIdentifier(request);
    return DarwinNotificationDetails(
      attachments: attachments.isEmpty ? null : attachments,
      categoryIdentifier: categoryIdentifier,
    );
  }

  int _notificationIntId(String id) => id.hashCode & 0x7FFFFFFF;

  void _onDidReceiveNotificationResponse(
    NotificationResponse response,
  ) {
    final listener = _eventListener;
    if (listener == null) {
      return;
    }
    final id = response.payload;
    if (id == null || id.isEmpty) {
      return;
    }
    if (response.notificationResponseType ==
        NotificationResponseType.selectedNotification) {
      unawaited(listener(AppNotificationEvent.dismissed(id: id)));
      return;
    }
    if (response.notificationResponseType !=
        NotificationResponseType.selectedNotificationAction) {
      return;
    }
    final actionId = response.actionId;
    if (actionId == null || actionId.isEmpty) {
      return;
    }
    final buttonIndex = _buttonIndexFromActionId(actionId);
    if (buttonIndex == null) {
      return;
    }
    unawaited(
      listener(
        AppNotificationEvent.actionInvoked(id: id, buttonIndex: buttonIndex),
      ),
    );
  }

  bool _registerDarwinCategoryIfNeeded(AppNotificationRequest? request) {
    if (!Platform.isIOS) {
      return false;
    }
    final identifier = _darwinCategoryIdentifier(request);
    if (identifier == null || _darwinCategories.containsKey(identifier)) {
      return false;
    }
    _darwinCategories[identifier] = DarwinNotificationCategory(
      identifier,
      actions: request!.buttons
          .asMap()
          .entries
          .map(
            (entry) => DarwinNotificationAction.plain(
              _actionId(entry.key),
              entry.value.label,
              options: switch (entry.value.color) {
                AppNotificationButtonColor.defaultColor =>
                  const <DarwinNotificationActionOption>{},
                AppNotificationButtonColor.red =>
                  <DarwinNotificationActionOption>{
                    DarwinNotificationActionOption.destructive,
                  },
              },
            ),
          )
          .toList(growable: false),
    );
    return true;
  }

  String? _darwinCategoryIdentifier(AppNotificationRequest? request) {
    if (request == null || request.buttons.isEmpty) {
      return null;
    }
    final signature = request.buttons
        .map((button) => '${button.label}|${button.color.name}')
        .join('||');
    return '$_darwinCategoryPrefix${signature.hashCode.toUnsigned(32).toRadixString(16)}';
  }

  String _actionId(int buttonIndex) => '$_actionIdPrefix$buttonIndex';

  int? _buttonIndexFromActionId(String actionId) {
    if (!actionId.startsWith(_actionIdPrefix)) {
      return null;
    }
    return int.tryParse(actionId.substring(_actionIdPrefix.length));
  }

  static Future<String> _writeTmpAttachment(String id, Uint8List bytes) async {
    final file = File(
      '${Directory.systemTemp.path}/sgtp_app_notif_${id.hashCode & 0x7FFFFFFF}.jpg',
    );
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }
}
