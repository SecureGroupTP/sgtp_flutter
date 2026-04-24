import 'package:path/path.dart' as p;
import 'package:sgtp_flutter/core/storage/account_storage_paths.dart';
import 'package:sgtp_flutter/core/storage/storage_key_service.dart';
import 'package:sgtp_flutter/features/notifications/data/storage/notification_inbox_database.dart';
import 'package:sgtp_flutter/features/notifications/domain/entities/notification_inbox_record.dart';
import 'package:sgtp_flutter/features/notifications/domain/repositories/notification_inbox_store.dart';

class NotificationInboxStoreImpl implements NotificationInboxStore {
  NotificationInboxStoreImpl({
    required AccountStoragePaths accountStoragePaths,
    required StorageKeyService storageKeyService,
  })  : _accountStoragePaths = accountStoragePaths,
        _storageKeyService = storageKeyService;

  final AccountStoragePaths _accountStoragePaths;
  final StorageKeyService _storageKeyService;
  final Map<String, Future<NotificationInboxDatabase>> _openByAccount =
      <String, Future<NotificationInboxDatabase>>{};

  @override
  Future<void> closeAccount(String accountId) async {
    final normalized = _normalizeAccountId(accountId);
    final future = _openByAccount.remove(normalized);
    if (future == null) {
      return;
    }
    final db = await future;
    await db.close();
  }

  @override
  Future<NotificationInboxRecord?> findByDedupKey(
    String accountId,
    String dedupKey,
  ) async {
    final db = await _open(accountId);
    return db.findByDedupKey(dedupKey);
  }

  @override
  Future<NotificationInboxRecord?> findLatestByCollapseKey(
    String accountId,
    String collapseKey,
  ) async {
    final db = await _open(accountId);
    return db.findLatestByCollapseKey(collapseKey);
  }

  @override
  Future<void> save(NotificationInboxRecord record) async {
    final db = await _open(record.accountId);
    await db.save(record);
  }

  Future<NotificationInboxDatabase> _open(String accountId) {
    final normalized = _normalizeAccountId(accountId);
    return _openByAccount.putIfAbsent(normalized, () async {
      final layout = await _accountStoragePaths.resolve(normalized);
      final key = await _storageKeyService.loadOrCreateAccountKey(normalized);
      final dbName = 'inbox_${layout.accountId}';
      final dbPath = layout.accountRootPath == null
          ? dbName
          : p.join(layout.accountRootPath!, 'notification_inbox.db');
      return openNotificationInboxDatabase(
        accountId: normalized,
        databaseName: dbName,
        databasePath: dbPath,
        encryptionKey: key,
      );
    });
  }

  String _normalizeAccountId(String accountId) {
    final normalized = accountId.trim();
    if (normalized.isEmpty) {
      return 'default';
    }
    return normalized;
  }
}
