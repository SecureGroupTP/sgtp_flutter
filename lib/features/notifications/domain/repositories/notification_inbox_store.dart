import 'package:sgtp_flutter/features/notifications/domain/entities/notification_inbox_record.dart';

abstract class NotificationInboxStore {
  Future<NotificationInboxRecord?> findByDedupKey(
    String accountId,
    String dedupKey,
  );

  Future<NotificationInboxRecord?> findLatestByCollapseKey(
    String accountId,
    String collapseKey,
  );

  Future<void> save(NotificationInboxRecord record);

  Future<void> closeAccount(String accountId);
}
