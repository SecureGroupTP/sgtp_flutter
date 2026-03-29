import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

  // ── SharedPreferences key for background-queued receipts ─────────────────
  // When the app is killed and the user taps "Mark as Read", we can't call
  // the Bloc directly (wrong isolate / not initialised).  We queue the IDs
  // to SharedPreferences and flush them the next time the chat page resumes.

  static const _prefsPendingKey = 'notif_pending_read';

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
    // Without notificationCategories here the action button never appears,
    // even if categoryIdentifier is set per-notification.
    final markReadAction = DarwinNotificationAction.plain(
      _actionRead,
      'Mark as Read',
      // foreground: brings app to front so the response callback fires reliably.
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
      onDidReceiveNotificationResponse: _onResponse,
      // Background/killed isolate handler — must be a top-level function.
      onDidReceiveBackgroundNotificationResponse: _backgroundHandler,
    );
    _initialized = true;

    if (Platform.isAndroid) {
      await _plugin
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();
    }
  }

  // ── Response handler (foreground, or background+showsUserInterface) ───────

  static void _onResponse(NotificationResponse details) {
    if (details.actionId == _actionRead &&
        details.payload != null &&
        details.payload!.isNotEmpty) {
      onMarkAsRead?.call(details.payload!);
    }
  }

  // ── Show ─────────────────────────────────────────────────────────────────

  static Future<void> showMessage({
    required String sender,
    required String body,
    required String messageId,
    Uint8List? avatarBytes,
  }) async {
    if (!_supported || !_initialized) return;

    // ── Android ──────────────────────────────────────────────────────────
    // showsUserInterface: true  ← KEY FIX:
    //   When the app is backgrounded (process alive), Android delivers action
    //   taps to onDidReceiveBackgroundNotificationResponse by default, where
    //   we cannot call the Bloc.  Setting showsUserInterface = true makes
    //   Android bring the app to the foreground on action tap, which routes
    //   the response back through onDidReceiveNotificationResponse — where
    //   onMarkAsRead is wired up correctly.
    const markAsReadAction = AndroidNotificationAction(
      _actionRead,
      'Mark as Read',
      cancelNotification: true,
      showsUserInterface: true,  // ← brings app to foreground → callback fires
    );

    AndroidNotificationDetails androidDetails;
    if (avatarBytes != null && avatarBytes.isNotEmpty) {
      final bmp = ByteArrayAndroidBitmap.fromBase64String(_toBase64(avatarBytes));
      androidDetails = AndroidNotificationDetails(
        _channelId, _channelName,
        channelDescription: 'Incoming SGTP messages',
        importance: Importance.high,
        priority:   Priority.high,
        largeIcon:  bmp,
        styleInformation: BigTextStyleInformation(body),
        actions: const [markAsReadAction],
      );
    } else {
      androidDetails = AndroidNotificationDetails(
        _channelId, _channelName,
        channelDescription: 'Incoming SGTP messages',
        importance: Importance.high,
        priority:   Priority.high,
        styleInformation: BigTextStyleInformation(body),
        actions: const [markAsReadAction],
      );
    }

    // ── iOS / macOS ───────────────────────────────────────────────────────
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

  // ── Flush queued receipts (call on chat-page resume) ──────────────────────

  /// Processes any "Mark as Read" taps that arrived while the app was killed.
  /// Call this from didChangeAppLifecycleState(resumed) or initState.
  static Future<void> flushPendingMarkAsRead() async {
    if (!_supported) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final pending = prefs.getStringList(_prefsPendingKey) ?? [];
      if (pending.isEmpty) return;
      await prefs.remove(_prefsPendingKey);
      for (final id in pending) {
        onMarkAsRead?.call(id);
      }
    } catch (_) {}
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
    final out = StringBuffer();
    var i = 0;
    while (i + 2 < bytes.length) {
      final b0 = bytes[i++], b1 = bytes[i++], b2 = bytes[i++];
      out.write(chars[(b0 >> 2) & 0x3F]);
      out.write(chars[((b0 & 0x3) << 4) | ((b1 >> 4) & 0xF)]);
      out.write(chars[((b1 & 0xF) << 2) | ((b2 >> 6) & 0x3)]);
      out.write(chars[b2 & 0x3F]);
    }
    if (i < bytes.length) {
      final b0 = bytes[i++];
      final b1 = i < bytes.length ? bytes[i] : 0;
      out.write(chars[(b0 >> 2) & 0x3F]);
      out.write(chars[((b0 & 0x3) << 4) | ((b1 >> 4) & 0xF)]);
      if (i <= bytes.length - 1) out.write(chars[(b1 & 0xF) << 2]);
      else out.write('=');
      out.write('=');
    }
    return out.toString();
  }

  static Future<String> _writeTmpAvatar(
      String messageId, Uint8List bytes) async {
    final file = File(
        '${Directory.systemTemp.path}/sgtp_av_${messageId.hashCode & 0x7FFFFFFF}.jpg');
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }
}

// ── Background isolate handler ────────────────────────────────────────────────
// Called when a notification action is tapped while the app is KILLED.
// Runs in a separate isolate — cannot access Blocs or Flutter widgets.
// We queue the messageId to SharedPreferences so the next app launch can flush it.
@pragma('vm:entry-point')
void _backgroundHandler(NotificationResponse details) async {
  if (details.actionId != 'mark_read') return;
  final id = details.payload;
  if (id == null || id.isEmpty) return;
  try {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList('notif_pending_read') ?? [];
    if (!list.contains(id)) {
      list.add(id);
      await prefs.setStringList('notif_pending_read', list);
    }
  } catch (_) {}
}
