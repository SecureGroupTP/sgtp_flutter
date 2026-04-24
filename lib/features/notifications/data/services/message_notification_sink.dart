import 'package:sgtp_flutter/features/messaging/application/services/message_notification_service.dart';
import 'package:sgtp_flutter/features/notifications/domain/entities/notification_event.dart';
import 'package:sgtp_flutter/features/notifications/domain/repositories/push_notification_sink.dart';

class MessageNotificationSink implements PushNotificationSink {
  MessageNotificationSink({
    required MessageNotificationService messageNotificationService,
  }) : _messageNotificationService = messageNotificationService;

  final MessageNotificationService _messageNotificationService;

  @override
  Future<void> showFriendRequest(NotificationEvent event) async {
    await _messageNotificationService.showFriendRequestEvent(
      accountId: event.accountId,
      eventId: event.eventId,
      segmentId: event.segmentId,
      peerId: event.peerId ?? event.segmentId ?? event.eventId,
      displayName: event.displayName ?? event.senderName ?? 'New activity',
      avatarBytes: event.senderAvatarBytes,
      actions: event.actions,
    );
  }

  @override
  Future<void> showMessage(NotificationEvent event) async {
    await _messageNotificationService.showMessageEvent(
      accountId: event.accountId,
      eventId: event.eventId,
      segmentId: event.segmentId,
      roomId: event.threadId ?? event.segmentId ?? event.eventId,
      senderId: event.senderId ?? '',
      senderName: event.senderName ?? 'New message',
      avatarBytes: event.senderAvatarBytes,
      messageCount: event.messageCount,
    );
  }
}
