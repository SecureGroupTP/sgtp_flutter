import 'dart:typed_data';

import 'package:sgtp_flutter/features/notifications/domain/entities/notification_action.dart';
import 'package:sgtp_flutter/features/notifications/domain/entities/notification_kind.dart';

class NotificationEvent {
  const NotificationEvent._({
    required this.eventId,
    required this.segmentId,
    required this.accountId,
    required this.kind,
    this.threadId,
    this.peerId,
    this.senderId,
    this.senderName,
    this.displayName,
    this.senderAvatarBytes,
    this.messageCount = 0,
    this.actions = const <NotificationAction>[],
  });

  factory NotificationEvent.message({
    required String eventId,
    required String? segmentId,
    required String accountId,
    required String threadId,
    required String senderId,
    required String senderName,
    Uint8List? senderAvatarBytes,
    int messageCount = 1,
  }) {
    return NotificationEvent._(
      eventId: eventId,
      segmentId: segmentId,
      accountId: accountId,
      kind: NotificationKind.message,
      threadId: threadId,
      senderId: senderId,
      senderName: senderName,
      senderAvatarBytes: senderAvatarBytes,
      messageCount: messageCount,
    );
  }

  factory NotificationEvent.friendRequest({
    required String eventId,
    required String? segmentId,
    required String accountId,
    required String peerId,
    required String displayName,
    Uint8List? senderAvatarBytes,
    List<NotificationAction> actions = const <NotificationAction>[],
  }) {
    return NotificationEvent._(
      eventId: eventId,
      segmentId: segmentId,
      accountId: accountId,
      kind: NotificationKind.friendRequest,
      peerId: peerId,
      displayName: displayName,
      senderAvatarBytes: senderAvatarBytes,
      actions: actions,
    );
  }

  final String eventId;
  final String? segmentId;
  final String accountId;
  final NotificationKind kind;
  final String? threadId;
  final String? peerId;
  final String? senderId;
  final String? senderName;
  final String? displayName;
  final Uint8List? senderAvatarBytes;
  final int messageCount;
  final List<NotificationAction> actions;

  NotificationEvent withAccountId(String accountId) {
    return NotificationEvent._(
      eventId: eventId,
      segmentId: segmentId,
      accountId: accountId,
      kind: kind,
      threadId: threadId,
      peerId: peerId,
      senderId: senderId,
      senderName: senderName,
      displayName: displayName,
      senderAvatarBytes: senderAvatarBytes,
      messageCount: messageCount,
      actions: actions,
    );
  }
}
