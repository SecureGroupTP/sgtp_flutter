import 'package:sgtp_flutter/features/notifications/domain/entities/notification_kind.dart';
import 'package:sgtp_flutter/features/notifications/domain/entities/notification_safe_payload.dart';

class NotificationInboxRecord {
  const NotificationInboxRecord({
    required this.eventId,
    required this.segmentId,
    required this.accountId,
    required this.threadId,
    required this.peerId,
    required this.kind,
    required this.shownAtMs,
    required this.dedupKey,
    required this.collapseKey,
    required this.safePayload,
  });

  final String eventId;
  final String? segmentId;
  final String accountId;
  final String? threadId;
  final String? peerId;
  final NotificationKind kind;
  final int shownAtMs;
  final String dedupKey;
  final String collapseKey;
  final NotificationSafePayload safePayload;
}
