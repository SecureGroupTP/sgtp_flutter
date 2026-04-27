import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sgtp_flutter/core/storage/main_database.dart';
import 'package:sgtp_flutter/features/notifications/data/storage/notification_inbox_database.dart';
import 'package:sgtp_flutter/features/notifications/domain/entities/notification_inbox_record.dart';
import 'package:sgtp_flutter/features/notifications/domain/entities/notification_kind.dart';
import 'package:sgtp_flutter/features/notifications/domain/entities/notification_safe_payload.dart';

const _tableName = 'notification_inbox';

Future<NotificationInboxDatabase> openNotificationInboxDatabaseBackend({
  required String accountId,
  required String databaseName,
  required String databasePath,
  required List<int> encryptionKey,
}) async {
  final parent = Directory(p.dirname(databasePath));
  if (!await parent.exists()) {
    await parent.create(recursive: true);
  }
  final db = await _databaseFactory().openDatabase(
    databasePath,
    options: OpenDatabaseOptions(
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
CREATE TABLE $_tableName (
  event_id TEXT PRIMARY KEY,
  segment_id TEXT,
  account_id TEXT NOT NULL,
  thread_id TEXT,
  peer_id TEXT,
  kind TEXT NOT NULL,
  shown_at_ms INTEGER NOT NULL,
  dedup_key TEXT NOT NULL UNIQUE,
  collapse_key TEXT NOT NULL,
  nonce BLOB NOT NULL,
  ciphertext BLOB NOT NULL
)
''');
        await db.execute(
          'CREATE INDEX ${_tableName}_collapse_idx ON $_tableName (collapse_key, shown_at_ms DESC)',
        );
      },
    ),
  );
  return _NativeNotificationInboxDatabase(
    db: db,
    cipher: MainDatabaseCipher(Uint8List.fromList(encryptionKey)),
  );
}

DatabaseFactory _databaseFactory() {
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    sqfliteFfiInit();
    return databaseFactoryFfi;
  }
  return sqflite.databaseFactory;
}

class _NativeNotificationInboxDatabase implements NotificationInboxDatabase {
  _NativeNotificationInboxDatabase({
    required Database db,
    required MainDatabaseCipher cipher,
  }) : _db = db,
       _cipher = cipher;

  final Database _db;
  final MainDatabaseCipher _cipher;

  @override
  Future<void> close() => _db.close();

  @override
  Future<NotificationInboxRecord?> findByDedupKey(String dedupKey) async {
    final rows = await _db.query(
      _tableName,
      where: 'dedup_key = ?',
      whereArgs: <Object?>[dedupKey],
      limit: 1,
    );
    if (rows.isEmpty) {
      return null;
    }
    return _mapRow(rows.first);
  }

  @override
  Future<NotificationInboxRecord?> findLatestByCollapseKey(
    String collapseKey,
  ) async {
    final rows = await _db.query(
      _tableName,
      where: 'collapse_key = ?',
      whereArgs: <Object?>[collapseKey],
      orderBy: 'shown_at_ms DESC',
      limit: 1,
    );
    if (rows.isEmpty) {
      return null;
    }
    return _mapRow(rows.first);
  }

  @override
  Future<void> save(NotificationInboxRecord record) async {
    final encrypted = await _cipher.encryptJson(record.safePayload.toJson());
    await _db.insert(_tableName, <String, Object?>{
      'event_id': record.eventId,
      'segment_id': record.segmentId,
      'account_id': record.accountId,
      'thread_id': record.threadId,
      'peer_id': record.peerId,
      'kind': record.kind.name,
      'shown_at_ms': record.shownAtMs,
      'dedup_key': record.dedupKey,
      'collapse_key': record.collapseKey,
      'nonce': encrypted.nonce,
      'ciphertext': encrypted.ciphertext,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<NotificationInboxRecord> _mapRow(Map<String, Object?> row) async {
    final payload = await _cipher.decryptJson(
      nonce: row['nonce'] as Uint8List,
      ciphertext: row['ciphertext'] as Uint8List,
    );
    final avatarRaw = payload['avatarBytes'];
    Uint8List? avatarBytes;
    if (avatarRaw is List<int>) {
      avatarBytes = Uint8List.fromList(avatarRaw);
    } else if (avatarRaw is String && avatarRaw.isNotEmpty) {
      avatarBytes = Uint8List.fromList(base64Decode(avatarRaw));
    }
    return NotificationInboxRecord(
      eventId: row['event_id'] as String? ?? '',
      segmentId: row['segment_id'] as String?,
      accountId: row['account_id'] as String? ?? '',
      threadId: row['thread_id'] as String?,
      peerId: row['peer_id'] as String?,
      kind: NotificationKind.values.byName(row['kind'] as String? ?? 'message'),
      shownAtMs: (row['shown_at_ms'] as num?)?.toInt() ?? 0,
      dedupKey: row['dedup_key'] as String? ?? '',
      collapseKey: row['collapse_key'] as String? ?? '',
      safePayload: NotificationSafePayload(
        title: payload['title'] as String? ?? 'New activity',
        subtitle: payload['subtitle'] as String?,
        body: payload['body'] as String? ?? payload['subtitle'] as String?,
        avatarBytes: avatarBytes,
      ),
    );
  }
}
