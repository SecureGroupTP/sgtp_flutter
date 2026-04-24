import 'package:sgtp_flutter/features/notifications/domain/entities/notification_action.dart';
import 'package:sgtp_flutter/features/notifications/domain/entities/notification_kind.dart';
import 'package:sgtp_flutter/features/notifications/domain/entities/notification_safe_payload.dart';

class NotificationProjection {
  const NotificationProjection({
    required this.shouldShow,
    required this.kind,
    required this.dedupKey,
    required this.collapseKey,
    required this.safePayload,
    this.actions = const <NotificationAction>[],
  });

  final bool shouldShow;
  final NotificationKind kind;
  final String dedupKey;
  final String collapseKey;
  final NotificationSafePayload safePayload;
  final List<NotificationAction> actions;
}
