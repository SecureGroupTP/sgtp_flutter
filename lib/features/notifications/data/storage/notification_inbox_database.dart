import 'package:sgtp_flutter/features/notifications/data/storage/notification_inbox_database_backend.dart';
import 'package:sgtp_flutter/features/notifications/domain/entities/notification_inbox_record.dart';

abstract class NotificationInboxDatabase {
  Future<void> close();

  Future<NotificationInboxRecord?> findByDedupKey(String dedupKey);

  Future<NotificationInboxRecord?> findLatestByCollapseKey(String collapseKey);

  Future<void> save(NotificationInboxRecord record);
}

Future<NotificationInboxDatabase> openNotificationInboxDatabase({
  required String accountId,
  required String databaseName,
  required String databasePath,
  required List<int> encryptionKey,
}) {
  return openNotificationInboxDatabaseBackend(
    accountId: accountId,
    databaseName: databaseName,
    databasePath: databasePath,
    encryptionKey: encryptionKey,
  );
}
