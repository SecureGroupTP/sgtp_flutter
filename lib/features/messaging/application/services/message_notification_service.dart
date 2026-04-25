import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:sgtp_flutter/features/notifications/application/services/notification_dispatcher.dart';
import 'package:sgtp_flutter/features/notifications/domain/entities/notification_action.dart';
import 'package:sgtp_flutter/features/notifications/domain/entities/notification_event.dart';

class MessageNotificationService {
  MessageNotificationService({
    required NotificationDispatcher notificationDispatcher,
  }) : _notificationDispatcher = notificationDispatcher {
    _ensureLifecycleObserver();
  }

  final NotificationDispatcher _notificationDispatcher;
  bool _lifecycleAttached = false;
  bool _appIsInteractive = true;
  String? _suppressedRoomId;
  String? _suppressedAccountId;

  Future<void> showMessageEvent({
    required String accountId,
    required String eventId,
    required String? segmentId,
    required String roomId,
    required String senderId,
    required String senderName,
    Uint8List? avatarBytes,
    int messageCount = 1,
  }) async {
    await _notificationDispatcher.dispatch(
      NotificationEvent.message(
        eventId: eventId,
        segmentId: segmentId,
        accountId: accountId,
        threadId: roomId,
        senderId: senderId,
        senderName: senderName,
        senderAvatarBytes: avatarBytes,
        messageCount: messageCount,
      ),
      suppressPresentation: _shouldSuppressForRoom(accountId, roomId),
    );
  }

  Future<void> showFriendRequestEvent({
    required String accountId,
    required String eventId,
    required String? segmentId,
    required String peerId,
    required String displayName,
    Uint8List? avatarBytes,
    List<NotificationAction> actions = const <NotificationAction>[],
  }) async {
    await _notificationDispatcher.dispatch(
      NotificationEvent.friendRequest(
        eventId: eventId,
        segmentId: segmentId,
        accountId: accountId,
        peerId: peerId,
        displayName: displayName,
        senderAvatarBytes: avatarBytes,
        actions: actions,
      ),
    );
  }

  Future<void> dismissFriendRequest(
    String accountId,
    String peerId,
  ) async {
    await _notificationDispatcher.dismissCollapseKey(
      '$accountId:friendRequest:${peerId.trim().toLowerCase()}',
    );
  }

  Future<void> dismissRoom(String accountId, String roomId) async {
    final normalizedRoomId = _normalizeRoomId(roomId);
    if (normalizedRoomId == null) {
      return;
    }
    await _notificationDispatcher.dismissCollapseKey(
      '$accountId:message:$normalizedRoomId',
    );
  }

  void setSuppressedRoomId(String? accountId, String? roomId) {
    _ensureLifecycleObserver();
    _suppressedAccountId = accountId?.trim();
    _suppressedRoomId = _normalizeRoomId(roomId);
    if (_suppressedRoomId != null && _suppressedAccountId != null && !kIsWeb && _appIsInteractive) {
      unawaited(dismissRoom(_suppressedAccountId!, _suppressedRoomId!));
    }
  }

  Future<void> cancelAll() async {
    await _notificationDispatcher.dismissAllActive();
  }

  bool _shouldSuppressForRoom(String accountId, String? roomId) {
    if (kIsWeb || !_appIsInteractive) {
      return false;
    }
    final normalized = _normalizeRoomId(roomId);
    if (normalized == null) {
      return false;
    }
    return normalized == _suppressedRoomId &&
        accountId.trim() == (_suppressedAccountId ?? '');
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

  String? _normalizeRoomId(String? roomId) {
    final normalized = roomId?.trim();
    if (normalized == null || normalized.isEmpty) {
      return null;
    }
    return normalized;
  }
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
