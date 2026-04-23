import 'dart:async';
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
  final Map<String, AppNotificationHandle> _handlesByMessageId =
      <String, AppNotificationHandle>{};
  final Map<String, Set<String>> _messageIdsByRoomId = <String, Set<String>>{};

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
    final handle = await AppNotifications.instance
        .builder()
        .setImage(resolvedAvatar)
        .setTitle(sender)
        .setSubtitle(body)
        .setDesktopDuration(const Duration(seconds: 6))
        .show();
    final previousHandle = _handlesByMessageId[messageId];
    _removeMessageIdFromRooms(messageId);
    if (previousHandle != null) {
      await previousHandle.dismiss();
    }
    _handlesByMessageId[messageId] = handle;
    final normalizedRoomId = _normalizeRoomId(roomId);
    if (normalizedRoomId != null) {
      _messageIdsByRoomId
          .putIfAbsent(normalizedRoomId, () => <String>{})
          .add(messageId);
    }
  }

  void setSuppressedRoomId(String? roomId) {
    _ensureLifecycleObserver();
    _suppressedRoomId = _normalizeRoomId(roomId);
    if (_suppressedRoomId != null &&
        !kIsWeb &&
        _appIsInteractive) {
      unawaited(dismissRoom(_suppressedRoomId!));
    }
  }

  Future<void> dismissMessage(String messageId) async {
    final handle = _handlesByMessageId.remove(messageId);
    if (handle == null) {
      return;
    }
    _removeMessageIdFromRooms(messageId);
    await handle.dismiss();
  }

  Future<void> dismissRoom(String roomId) async {
    final normalizedRoomId = _normalizeRoomId(roomId);
    if (normalizedRoomId == null) {
      return;
    }
    final messageIds = _messageIdsByRoomId.remove(normalizedRoomId);
    if (messageIds == null || messageIds.isEmpty) {
      return;
    }
    for (final messageId in messageIds) {
      final handle = _handlesByMessageId.remove(messageId);
      if (handle != null) {
        await handle.dismiss();
      }
    }
  }

  Future<void> cancelAll() async {
    _handlesByMessageId.clear();
    _messageIdsByRoomId.clear();
    await AppNotifications.instance.dismissAll();
  }

  bool _shouldSuppressForRoom(String? roomId) {
    if (kIsWeb || !_appIsInteractive) {
      return false;
    }
    final normalized = _normalizeRoomId(roomId);
    if (normalized == null) {
      return false;
    }
    return normalized == _suppressedRoomId;
  }

  String? _normalizeRoomId(String? roomId) {
    final normalized = roomId?.trim();
    if (normalized == null || normalized.isEmpty) {
      return null;
    }
    return normalized;
  }

  void _removeMessageIdFromRooms(String messageId) {
    for (final entry in _messageIdsByRoomId.entries.toList()) {
      entry.value.remove(messageId);
      if (entry.value.isEmpty) {
        _messageIdsByRoomId.remove(entry.key);
      }
    }
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
