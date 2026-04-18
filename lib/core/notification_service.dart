import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show ValueNotifier, kIsWeb;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:windows_notification/notification_message.dart';
import 'package:windows_notification/windows_notification.dart';

/// Windows toast notifications (messages).
///
/// Other platforms: silently no-op (as requested).
class NotificationService {
  NotificationService._();

  static const _prefsEnabledKey = 'sgtp_notifications_enabled_v1';

  static final ValueNotifier<bool> enabled = ValueNotifier<bool>(true);

  static WindowsNotification? _win;
  static bool _loadedPrefs = false;

  static bool get _supported => !kIsWeb && Platform.isWindows;

  static String? _windowsApplicationId() {
    // windows_notification README: applicationId must be null in packaged mode.
    const isRelease = bool.fromEnvironment('dart.vm.product');
    if (isRelease) return null;
    try {
      final exe = Platform.resolvedExecutable.trim();
      return exe.isEmpty ? null : exe;
    } catch (_) {
      return null;
    }
  }

  static Future<void> init() async {
    if (!_supported) return;
    if (_win != null) return;

    await _loadEnabledIfNeeded();

    _win = WindowsNotification(applicationId: _windowsApplicationId());
    await _win!.init();
  }

  static Future<void> _loadEnabledIfNeeded() async {
    if (_loadedPrefs) return;
    _loadedPrefs = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      enabled.value = prefs.getBool(_prefsEnabledKey) ?? true;
    } catch (_) {
      enabled.value = true;
    }
  }

  static Future<bool> loadEnabled() async {
    await _loadEnabledIfNeeded();
    return enabled.value;
  }

  static Future<void> setEnabled(bool value) async {
    enabled.value = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefsEnabledKey, value);
    } catch (_) {}
  }

  static Future<void> showChatMessageCount({
    required String chatId,
    required String chatName,
    required int newMessagesCount,
    Uint8List? avatarBytes,
  }) async {
    if (!_supported) return;
    if (newMessagesCount <= 0) return;
    await _loadEnabledIfNeeded();
    if (!enabled.value) return;

    await init();
    final win = _win;
    if (win == null) return;

    final body =
        'You got $newMessagesCount new message${newMessagesCount == 1 ? '' : 's'}';
    final imagePath = await _writeTmpAvatar(chatId, avatarBytes);
    final id = '${chatId}_${DateTime.now().millisecondsSinceEpoch}';
    final message = NotificationMessage.fromPluginTemplate(
      id,
      chatName.trim().isEmpty ? 'Chat' : chatName,
      body,
      image: imagePath,
      group: 'chat_$chatId',
      payload: <String, dynamic>{
        'chatId': chatId,
        'count': newMessagesCount,
      },
    );
    try {
      await win.showNotificationPluginTemplate(message);
    } catch (_) {}
  }

  static Future<void> cancelAll() async {
    if (!_supported) return;
    await init();
    try {
      await _win?.clearNotificationHistory();
    } catch (_) {}
  }

  static Future<String?> _writeTmpAvatar(
    String chatId,
    Uint8List? bytes,
  ) async {
    if (bytes == null || bytes.isEmpty) return null;
    try {
      final safe = chatId.hashCode & 0x7FFFFFFF;
      final file = File('${Directory.systemTemp.path}/sgtp_chat_$safe.jpg');
      await file.writeAsBytes(bytes, flush: true);
      return file.path;
    } catch (_) {
      return null;
    }
  }
}
