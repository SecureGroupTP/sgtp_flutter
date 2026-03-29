import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Handles local push notifications (Android / iOS / macOS).
/// On Windows/Linux desktop — silently no-ops.
class NotificationService {
  NotificationService._();

  static final _plugin = FlutterLocalNotificationsPlugin();
  static bool _initialized = false;

  /// Called when the user taps "Mark as Read" in a notification.
  static void Function(String messageId)? onMarkAsRead;

  // ── Android channel ──────────────────────────────────────────────────────

  static const _channelId   = 'sgtp_messages';
  static const _channelName = 'Messages';
  static const _actionRead  = 'mark_read';

  // ── iOS / macOS category ─────────────────────────────────────────────────

  static const _categoryId  = 'sgtp_message';

  // ── Platform guard ───────────────────────────────────────────────────────

  static bool get _supported =>
      !kIsWeb &&
      (Platform.isAndroid || Platform.isIOS || Platform.isMacOS);

  // ── Init ─────────────────────────────────────────────────────────────────

  static Future<void> init() async {
    if (!_supported || _initialized) return;

    const androidSettings =
        AndroidInitializationSettings('@mipmap/ic_launcher');

    // Register the 'mark_read' action category for iOS & macOS.
    // Without notificationCategories here, the action button never appears
    // on Darwin platforms even if categoryIdentifier is set on each notification.
    final markReadAction = DarwinNotificationAction.plain(
      _actionRead,
      'Mark as Read',
      options: {DarwinNotificationActionOption.foreground},
    );
    final darwinCategory = DarwinNotificationCategory(
      _categoryId,
      actions: [markReadAction],
    );
    final darwinSettings = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
      notificationCategories: [darwinCategory],
    );

    await _plugin.initialize(
      InitializationSettings(
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
      // Also handle action taps when app was launched from a notification
      // (background-terminated state on iOS/Android).
      onDidReceiveBackgroundNotificationResponse: _backgroundHandler,
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
  /// [messageId] is used as the payload for "Mark as Read".
  /// [avatarBytes] is optional — shown as the large icon on Android and as
  /// an attachment thumbnail on iOS/macOS.
  static Future<void> showMessage({
    required String sender,
    required String body,
    required String messageId,
    Uint8List? avatarBytes,
  }) async {
    if (!_supported || !_initialized) return;

    // ── Android ──────────────────────────────────────────────────────────
    AndroidNotificationDetails androidDetails;

    if (avatarBytes != null && avatarBytes.isNotEmpty) {
      final androidBitmap =
          ByteArrayAndroidBitmap.fromBase64String(_toBase64(avatarBytes));
      androidDetails = AndroidNotificationDetails(
        _channelId,
        _channelName,
        channelDescription: 'Incoming SGTP messages',
        importance: Importance.high,
        priority: Priority.high,
        largeIcon: androidBitmap,
        styleInformation: BigTextStyleInformation(body),
        actions: [
          const AndroidNotificationAction(
            _actionRead,
            'Mark as Read',
            cancelNotification: true,
          ),
        ],
      );
    } else {
      androidDetails = AndroidNotificationDetails(
        _channelId,
        _channelName,
        channelDescription: 'Incoming SGTP messages',
        importance: Importance.high,
        priority: Priority.high,
        styleInformation: BigTextStyleInformation(body),
        actions: [
          const AndroidNotificationAction(
            _actionRead,
            'Mark as Read',
            cancelNotification: true,
          ),
        ],
      );
    }

    // ── iOS / macOS ───────────────────────────────────────────────────────
    // Attach avatar as a thumbnail image if available.
    DarwinNotificationDetails darwinDetails;
    if (avatarBytes != null && avatarBytes.isNotEmpty) {
      try {
        final tmpPath = await _writeTmpAvatar(messageId, avatarBytes);
        darwinDetails = DarwinNotificationDetails(
          categoryIdentifier: _categoryId,
          attachments: [DarwinNotificationAttachment(tmpPath)],
        );
      } catch (_) {
        darwinDetails = const DarwinNotificationDetails(
          categoryIdentifier: _categoryId,
        );
      }
    } else {
      darwinDetails = const DarwinNotificationDetails(
        categoryIdentifier: _categoryId,
      );
    }

    await _plugin.show(
      messageId.hashCode & 0x7FFFFFFF,
      sender,
      body,
      NotificationDetails(
          android: androidDetails, iOS: darwinDetails, macOS: darwinDetails),
      payload: messageId,
    );
  }

  // ── Cancel ───────────────────────────────────────────────────────────────

  static Future<void> cancelAll() async {
    if (!_supported || !_initialized) return;
    await _plugin.cancelAll();
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  static String _toBase64(Uint8List bytes) {
    const chars =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
    final output = StringBuffer();
    var i = 0;
    while (i + 2 < bytes.length) {
      final b0 = bytes[i++], b1 = bytes[i++], b2 = bytes[i++];
      output.write(chars[(b0 >> 2) & 0x3F]);
      output.write(chars[((b0 & 0x3) << 4) | ((b1 >> 4) & 0xF)]);
      output.write(chars[((b1 & 0xF) << 2) | ((b2 >> 6) & 0x3)]);
      output.write(chars[b2 & 0x3F]);
    }
    if (i < bytes.length) {
      final b0 = bytes[i++];
      final b1 = i < bytes.length ? bytes[i] : 0;
      output.write(chars[(b0 >> 2) & 0x3F]);
      output.write(chars[((b0 & 0x3) << 4) | ((b1 >> 4) & 0xF)]);
      if (i <= bytes.length - 1) output.write(chars[((b1 & 0xF) << 2)]);
      else output.write('=');
      output.write('=');
    }
    return output.toString();
  }

  /// Write avatar bytes to a temp file and return its path.
  /// iOS/macOS DarwinNotificationAttachment needs a file path.
  static Future<String> _writeTmpAvatar(
      String messageId, Uint8List bytes) async {
    final dir = Directory.systemTemp;
    final file = File(
        '${dir.path}/sgtp_avatar_${messageId.hashCode & 0x7FFFFFFF}.jpg');
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }
}

/// Top-level function required by flutter_local_notifications for background
/// notification action handling (iOS/Android killed state).
/// Must be a top-level function (not a class method).
@pragma('vm:entry-point')
void _backgroundHandler(NotificationResponse details) {
  // When the app is killed, we can't call the Bloc directly.
  // The receipt will be sent on next resume via _flushPendingReadReceipts.
  // Nothing to do here — the callback is required to be registered so the
  // plugin doesn't drop the action event on iOS.
}
