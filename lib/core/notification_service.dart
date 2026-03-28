import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Handles local push notifications (Android / iOS / macOS).
/// On Windows/Linux desktop — silently no-ops.
class NotificationService {
  NotificationService._();

  static final _plugin = FlutterLocalNotificationsPlugin();
  static bool _initialized = false;

  /// Called when the user taps "Mark as Read" in a notification.
  /// Provides the messageId that should be marked read.
  static void Function(String messageId)? onMarkAsRead;

  // ── Android channel ──────────────────────────────────────────────────────

  static const _channelId   = 'sgtp_messages';
  static const _channelName = 'Messages';
  static const _actionRead  = 'mark_read';

  // ── Platform guard ───────────────────────────────────────────────────────

  /// We only show notifications on mobile / macOS.
  static bool get _supported =>
      !kIsWeb &&
      (Platform.isAndroid || Platform.isIOS || Platform.isMacOS);

  // ── Init ─────────────────────────────────────────────────────────────────

  static Future<void> init() async {
    if (!_supported || _initialized) return;

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
        iOS:     darwinSettings,
        macOS:   darwinSettings,
      ),
      onDidReceiveNotificationResponse: (details) {
        if (details.actionId == _actionRead &&
            details.payload != null &&
            details.payload!.isNotEmpty) {
          onMarkAsRead?.call(details.payload!);
        }
      },
    );
    _initialized = true;

    // Ask for Android 13+ POST_NOTIFICATIONS permission
    if (Platform.isAndroid) {
      await _plugin
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();
    }
  }

  // ── Show ─────────────────────────────────────────────────────────────────

  /// Show a notification for a new incoming message.
  /// [messageId] is used as the payload so "Mark as Read" knows which
  /// message to acknowledge; it also de-duplicates notifications by id.
  static Future<void> showMessage({
    required String sender,
    required String body,
    required String messageId,
  }) async {
    if (!_supported || !_initialized) return;

    final androidDetails = AndroidNotificationDetails(
      _channelId,
      _channelName,
      channelDescription: 'Incoming SGTP messages',
      importance: Importance.high,
      priority:   Priority.high,
      styleInformation: BigTextStyleInformation(body),
      actions: [
        const AndroidNotificationAction(
          _actionRead,
          'Mark as Read',
          cancelNotification: true,
        ),
      ],
    );

    const darwinDetails = DarwinNotificationDetails(
      categoryIdentifier: 'sgtp_message',
    );

    await _plugin.show(
      messageId.hashCode & 0x7FFFFFFF, // unique int id
      sender,
      body,
      NotificationDetails(android: androidDetails, iOS: darwinDetails, macOS: darwinDetails),
      payload: messageId,
    );
  }

  // ── Cancel ───────────────────────────────────────────────────────────────

  static Future<void> cancelAll() async {
    if (!_supported || !_initialized) return;
    await _plugin.cancelAll();
  }
}
