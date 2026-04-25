import 'dart:convert';
import 'dart:typed_data';

import 'package:idb_shim/idb_browser.dart';
import 'package:sgtp_flutter/core/storage/main_database.dart';
import 'package:sgtp_flutter/features/notifications/data/storage/notification_inbox_database.dart';
import 'package:sgtp_flutter/features/notifications/domain/entities/notification_inbox_record.dart';
import 'package:sgtp_flutter/features/notifications/domain/entities/notification_kind.dart';
import 'package:sgtp_flutter/features/notifications/domain/entities/notification_safe_payload.dart';

const _storeName = 'notification_inbox';

Future<NotificationInboxDatabase> openNotificationInboxDatabaseBackend({
  required String accountId,
  required String databaseName,
  required String databasePath,
  required List<int> encryptionKey,
}) async {
  final idbFactory = getIdbFactory();
  if (idbFactory == null) {
    throw UnsupportedError('IndexedDB is not available');
  }
  final db = await idbFactory.open(
    databaseName,
    version: 1,
    onUpgradeNeeded: (event) {
      final db = event.database;
      if (!db.objectStoreNames.contains(_storeName)) {
        db.createObjectStore(_storeName);
      }
    },
  );
  return _WebNotificationInboxDatabase(
    db: db,
    cipher: MainDatabaseCipher(Uint8List.fromList(encryptionKey)),
  );
}

class _WebNotificationInboxDatabase implements NotificationInboxDatabase {
  _WebNotificationInboxDatabase({
    required Database db,
    required MainDatabaseCipher cipher,
  })  : _db = db,
        _cipher = cipher;

  final Database _db;
  final MainDatabaseCipher _cipher;

  @override
  Future<void> close() async => _db.close();

  @override
  Future<NotificationInboxRecord?> findByDedupKey(String dedupKey) async {
    final records = await _loadAll();
    for (final record in records) {
      if (record.dedupKey == dedupKey) {
        return record;
      }
    }
    return null;
  }

  @override
  Future<NotificationInboxRecord?> findLatestByCollapseKey(
    String collapseKey,
  ) async {
    final records = await _loadAll();
    NotificationInboxRecord? latest;
    for (final record in records) {
      if (record.collapseKey != collapseKey) {
        continue;
      }
      if (latest == null || record.shownAtMs > latest.shownAtMs) {
        latest = record;
      }
    }
    return latest;
  }

  @override
  Future<void> save(NotificationInboxRecord record) async {
    final encrypted = await _cipher.encryptJson(record.safePayload.toJson());
    final txn = _db.transaction(_storeName, idbModeReadWrite);
    final store = txn.objectStore(_storeName);
    await store.put(
      <String, Object?>{
        'eventId': record.eventId,
        'segmentId': record.segmentId,
        'accountId': record.accountId,
        'threadId': record.threadId,
        'peerId': record.peerId,
        'kind': record.kind.name,
        'shownAtMs': record.shownAtMs,
        'dedupKey': record.dedupKey,
        'collapseKey': record.collapseKey,
        'nonce': base64Encode(encrypted.nonce),
        'ciphertext': base64Encode(encrypted.ciphertext),
      },
      record.eventId,
    );
    await txn.completed;
  }

  Future<List<NotificationInboxRecord>> _loadAll() async {
    final txn = _db.transaction(_storeName, idbModeReadOnly);
    final store = txn.objectStore(_storeName);
    final values = <Map<String, dynamic>>[];
    await store.openCursor(autoAdvance: true).forEach((cursor) {
      final value = cursor.value;
      if (value is Map) {
        values.add(Map<String, dynamic>.from(value));
      }
    });
    await txn.completed;
    final records = <NotificationInboxRecord>[];
    for (final value in values) {
      records.add(await _mapRecord(value));
    }
    return records;
  }

  Future<NotificationInboxRecord> _mapRecord(Map<String, dynamic> value) async {
    final payload = await _cipher.decryptJson(
      nonce: Uint8List.fromList(base64Decode(value['nonce'] as String? ?? '')),
      ciphertext: Uint8List.fromList(
        base64Decode(value['ciphertext'] as String? ?? ''),
      ),
    );
    final avatarRaw = payload['avatarBytes'];
    Uint8List? avatarBytes;
    if (avatarRaw is List<int>) {
      avatarBytes = Uint8List.fromList(avatarRaw);
    }
    return NotificationInboxRecord(
      eventId: value['eventId'] as String? ?? '',
      segmentId: value['segmentId'] as String?,
      accountId: value['accountId'] as String? ?? '',
      threadId: value['threadId'] as String?,
      peerId: value['peerId'] as String?,
      kind: NotificationKind.values.byName(value['kind'] as String? ?? 'message'),
      shownAtMs: (value['shownAtMs'] as num?)?.toInt() ?? 0,
      dedupKey: value['dedupKey'] as String? ?? '',
      collapseKey: value['collapseKey'] as String? ?? '',
      safePayload: NotificationSafePayload(
        title: payload['title'] as String? ?? 'New activity',
        subtitle: payload['subtitle'] as String?,
        avatarBytes: avatarBytes,
      ),
    );
  }
}
