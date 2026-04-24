import 'package:sgtp_flutter/features/notifications/domain/entities/notification_account_context.dart';
import 'package:sgtp_flutter/features/notifications/domain/entities/notification_event.dart';
import 'package:sgtp_flutter/features/notifications/domain/entities/notification_kind.dart';
import 'package:sgtp_flutter/features/notifications/domain/entities/notification_projection.dart';
import 'package:sgtp_flutter/features/notifications/domain/entities/notification_safe_payload.dart';

class NotificationProjectionService {
  const NotificationProjectionService();

  NotificationProjection project(
    NotificationEvent event,
    NotificationAccountContext accountContext,
  ) {
    final dedupKey = '${event.accountId}:${event.eventId}';
    final collapseTarget = switch (event.kind) {
      NotificationKind.message => event.threadId ?? event.segmentId ?? event.eventId,
      NotificationKind.friendRequest =>
        event.peerId ?? event.segmentId ?? event.eventId,
    };
    final collapseKey =
        '${event.accountId}:${event.kind.name}:$collapseTarget';

    if (accountContext.genericOnly) {
      return NotificationProjection(
        shouldShow: true,
        kind: event.kind,
        dedupKey: dedupKey,
        collapseKey: collapseKey,
        safePayload: NotificationSafePayload(
          title: switch (event.kind) {
            NotificationKind.message => 'New message',
            NotificationKind.friendRequest => 'New activity',
          },
        ),
        actions: event.actions,
      );
    }

    return NotificationProjection(
      shouldShow: true,
      kind: event.kind,
      dedupKey: dedupKey,
      collapseKey: collapseKey,
      safePayload: NotificationSafePayload(
        title: switch (event.kind) {
          NotificationKind.message => _normalizeLabel(event.senderName, fallback: 'New message'),
          NotificationKind.friendRequest =>
            _normalizeLabel(event.displayName, fallback: 'New activity'),
        },
        subtitle: switch (event.kind) {
          NotificationKind.message => _messageSubtitle(event.messageCount),
          NotificationKind.friendRequest => 'Sent you a friend request',
        },
        avatarBytes: event.senderAvatarBytes,
      ),
      actions: event.actions,
    );
  }

  String _messageSubtitle(int messageCount) {
    if (messageCount <= 1) {
      return '1 new message';
    }
    return '$messageCount new messages';
  }

  String _normalizeLabel(String? value, {required String fallback}) {
    final normalized = value?.trim();
    if (normalized == null || normalized.isEmpty) {
      return fallback;
    }
    return normalized;
  }
}
