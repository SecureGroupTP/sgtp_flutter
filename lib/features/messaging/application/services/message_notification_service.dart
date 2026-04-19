import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:sgtp_flutter/core/app_notifications/app_notifications.dart';
import 'package:sgtp_flutter/core/app_notifications/notification_avatar_image.dart';

class MessageNotificationService {
  MessageNotificationService() {
    _ensureLifecycleObserver();
  }

  bool _lifecycleAttached = false;
  bool _appIsInteractive = true;
  String? _suppressedRoomId;

  Future<void> showMessage({
    required String sender,
    required String body,
    required String messageId,
    String? roomId,
    Uint8List? avatarBytes,
  }) async {
    if (_shouldSuppressForRoom(roomId)) {
      return;
    }
    final resolvedAvatar = await NotificationAvatarImage.resolve(
      avatarBytes: avatarBytes,
      fallbackName: sender,
    );
    await AppNotifications.instance
        .builder()
        .setImage(resolvedAvatar)
        .setTitle(sender)
        .setSubtitle(body)
        .setDuration(const Duration(seconds: 6))
        .show();
  }

  void setSuppressedRoomId(String? roomId) {
    _ensureLifecycleObserver();
    final normalized = roomId?.trim();
    _suppressedRoomId =
        normalized == null || normalized.isEmpty ? null : normalized;
  }

  Future<void> cancelAll() => AppNotifications.instance.dismissAll();

  bool _shouldSuppressForRoom(String? roomId) {
    if (kIsWeb || !_appIsInteractive) {
      return false;
    }
    final normalized = roomId?.trim();
    if (normalized == null || normalized.isEmpty) {
      return false;
    }
    return normalized == _suppressedRoomId;
  }

  void _ensureLifecycleObserver() {
    if (kIsWeb || _lifecycleAttached) {
      return;
    }
    WidgetsBinding.instance.addObserver(_lifecycleObserver);
    _lifecycleAttached = true;
  }

  late final WidgetsBindingObserver _lifecycleObserver =
      _MessageNotificationLifecycleObserver(this);
}

class _MessageNotificationLifecycleObserver with WidgetsBindingObserver {
  _MessageNotificationLifecycleObserver(this._owner);

  final MessageNotificationService _owner;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        _owner._appIsInteractive = true;
        break;
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        _owner._appIsInteractive = false;
        break;
    }
  }
}
