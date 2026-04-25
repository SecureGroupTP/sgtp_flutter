import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_common/sqlite_api.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'main_database.dart';
import 'main_database_migrator.dart';
import 'main_database_schema.dart';

Future<MainDatabase> openMainDatabase({
  required String accountId,
  required String databaseName,
  required String databasePath,
  required Uint8List encryptionKey,
}) async {
  final parent = Directory(p.dirname(databasePath));
  if (!await parent.exists()) {
    await parent.create(recursive: true);
  }

  final databaseFactory = _resolveDatabaseFactory();
  final migrator = MainDatabaseMigrator();
  final db = await databaseFactory.openDatabase(
    databasePath,
    options: OpenDatabaseOptions(
      version: MainDatabaseSchema.currentVersion,
      onCreate: (db, version) async {
        await _applyMigrations(db, upToVersion: version, migrator: migrator);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        await _applyMigrations(
          db,
          fromVersion: oldVersion + 1,
          upToVersion: newVersion,
          migrator: migrator,
        );
      },
    ),
  );
  return _NativeMainDatabase(
    db: db,
    cipher: MainDatabaseCipher(encryptionKey),
  );
}

Future<void> deleteMainDatabase({
  required String accountId,
  required String databaseName,
  required String databasePath,
}) async {
  final databaseFactory = _resolveDatabaseFactory();
  await databaseFactory.deleteDatabase(databasePath);
}

DatabaseFactory _resolveDatabaseFactory() {
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    sqfliteFfiInit();
    return databaseFactoryFfi;
  }
  return sqflite.databaseFactory;
}

Future<void> _applyMigrations(
  DatabaseExecutor db, {
  int fromVersion = 1,
  required int upToVersion,
  required MainDatabaseMigrator migrator,
}) async {
  for (final migration in migrator.migrations) {
    if (migration.version < fromVersion || migration.version > upToVersion) {
      continue;
    }
    for (final statement in migration.statements) {
      await db.execute(statement);
    }
  }
}

class _NativeMainDatabase implements MainDatabase {
  _NativeMainDatabase({
    required Database db,
    required MainDatabaseCipher cipher,
  })  : _db = db,
        _cipher = cipher;

  final Database _db;
  final MainDatabaseCipher _cipher;

  @override
  Future<void> close() => _db.close();

  @override
  Future<void> saveSettingString(String key, String value) {
    return upsertSettingJson(key, <String, dynamic>{'value': value});
  }

  @override
  Future<String?> loadSettingString(String key) async {
    final payload = await loadSettingJson(key);
    final value = (payload?['value'] as String?)?.trim();
    if (value == null || value.isEmpty) return null;
    return value;
  }

  @override
  Future<void> saveSettingBytes(String key, Uint8List value) {
    return upsertSettingJson(key, <String, dynamic>{
      'b64': base64Encode(value),
    });
  }

  @override
  Future<Uint8List?> loadSettingBytes(String key) async {
    final payload = await loadSettingJson(key);
    final raw = payload?['b64'] as String?;
    if (raw == null || raw.isEmpty) return null;
    try {
      return Uint8List.fromList(base64Decode(raw));
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> upsertSettingJson(String key, Map<String, dynamic> value) async {
    final encrypted = await _cipher.encryptJson(value);
    await _db.insert(
      MainDatabaseSchema.settingsTable,
      <String, Object?>{
        'record_key': key,
        'nonce': encrypted.nonce,
        'ciphertext': encrypted.ciphertext,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  @override
  Future<Map<String, dynamic>?> loadSettingJson(String key) async {
    final rows = await _db.query(
      MainDatabaseSchema.settingsTable,
      where: 'record_key = ?',
      whereArgs: <Object?>[key],
      limit: 1,
    );
    final row = rows.isEmpty ? null : rows.first;
    if (row == null) return null;
    return _decryptRow(row);
  }

  @override
  Future<void> deleteSetting(String key) {
    return _db.delete(
      MainDatabaseSchema.settingsTable,
      where: 'record_key = ?',
      whereArgs: <Object?>[key],
    );
  }

  @override
  Future<void> replaceContactEntries(
    List<MainDatabaseContactEntryRecord> entries,
  ) async {
    final batch = _db.batch();
    batch.delete(MainDatabaseSchema.contactEntriesTable);
    for (final entry in entries) {
      final encrypted = await _cipher.encryptJson(<String, dynamic>{
        'peerPubkeyB64': base64Encode(entry.peerPubkeyBytes),
        'displayName': entry.displayName,
      });
      batch.insert(
        MainDatabaseSchema.contactEntriesTable,
        <String, Object?>{
          'peer_pubkey_hex': entry.peerPubkeyHex,
          'updated_at': entry.updatedAtMs,
          'nonce': encrypted.nonce,
          'ciphertext': encrypted.ciphertext,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
  }

  @override
  Future<List<MainDatabaseContactEntryRecord>> loadContactEntries() async {
    final rows = await _db.query(
      MainDatabaseSchema.contactEntriesTable,
      orderBy: 'updated_at DESC, peer_pubkey_hex ASC',
    );
    final out = <MainDatabaseContactEntryRecord>[];
    for (final row in rows) {
      final payload = await _decryptRow(row);
      final bytesB64 = payload['peerPubkeyB64'] as String? ?? '';
      Uint8List peerBytes;
      try {
        peerBytes = Uint8List.fromList(base64Decode(bytesB64));
      } catch (_) {
        continue;
      }
      out.add(
        MainDatabaseContactEntryRecord(
          peerPubkeyHex: row['peer_pubkey_hex'] as String? ?? '',
          peerPubkeyBytes: peerBytes,
          displayName: payload['displayName'] as String? ?? 'unknown',
          updatedAtMs: (row['updated_at'] as num?)?.toInt() ?? 0,
        ),
      );
    }
    return out;
  }

  @override
  Future<void> saveContactProfile(MainDatabaseContactProfileRecord profile) async {
    final encrypted = await _cipher.encryptJson(<String, dynamic>{
      'username': profile.username,
      'fullname': profile.fullname,
      'avatarB64': profile.avatarBytes == null
          ? null
          : base64Encode(profile.avatarBytes!),
      'avatarSha256Hex': profile.avatarSha256Hex,
    });
    await _db.insert(
      MainDatabaseSchema.contactProfilesTable,
      <String, Object?>{
        'peer_pubkey_hex': profile.peerPubkeyHex,
        'updated_at': profile.updatedAtMs,
        'nonce': encrypted.nonce,
        'ciphertext': encrypted.ciphertext,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  @override
  Future<MainDatabaseContactProfileRecord?> loadContactProfile(
    String peerPubkeyHex,
  ) async {
    final rows = await _db.query(
      MainDatabaseSchema.contactProfilesTable,
      where: 'peer_pubkey_hex = ?',
      whereArgs: <Object?>[peerPubkeyHex],
      limit: 1,
    );
    final row = rows.isEmpty ? null : rows.first;
    if (row == null) return null;
    return _mapContactProfileRow(row);
  }

  @override
  Future<List<MainDatabaseContactProfileRecord>> loadAllContactProfiles() async {
    final rows = await _db.query(
      MainDatabaseSchema.contactProfilesTable,
      orderBy: 'updated_at DESC, peer_pubkey_hex ASC',
    );
    final out = <MainDatabaseContactProfileRecord>[];
    for (final row in rows) {
      final mapped = await _mapContactProfileRow(row);
      if (mapped != null) {
        out.add(mapped);
      }
    }
    return out;
  }

  @override
  Future<void> replaceFriendStates(
    List<MainDatabaseFriendStateRecord> states,
  ) async {
    final batch = _db.batch();
    batch.delete(MainDatabaseSchema.friendStatesTable);
    for (final state in states) {
      final encrypted = await _cipher.encryptJson(<String, dynamic>{
        'status': state.status,
        'roomUuidHex': state.roomUuidHex,
      });
      batch.insert(
        MainDatabaseSchema.friendStatesTable,
        <String, Object?>{
          'peer_pubkey_hex': state.peerPubkeyHex,
          'updated_at': state.updatedAtMs,
          'nonce': encrypted.nonce,
          'ciphertext': encrypted.ciphertext,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
  }

  @override
  Future<List<MainDatabaseFriendStateRecord>> loadFriendStates() async {
    final rows = await _db.query(
      MainDatabaseSchema.friendStatesTable,
      orderBy: 'updated_at DESC, peer_pubkey_hex ASC',
    );
    final out = <MainDatabaseFriendStateRecord>[];
    for (final row in rows) {
      final payload = await _decryptRow(row);
      out.add(
        MainDatabaseFriendStateRecord(
          peerPubkeyHex: row['peer_pubkey_hex'] as String? ?? '',
          status: payload['status'] as String? ?? '',
          roomUuidHex: (payload['roomUuidHex'] as String?)?.trim(),
          updatedAtMs: (row['updated_at'] as num?)?.toInt() ?? 0,
        ),
      );
    }
    return out;
  }

  @override
  Future<void> replaceSuppressedContacts(Set<String> peerPubkeyHexes) async {
    final batch = _db.batch();
    batch.delete(MainDatabaseSchema.suppressedContactsTable);
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final peerPubkeyHex in peerPubkeyHexes) {
      batch.insert(
        MainDatabaseSchema.suppressedContactsTable,
        <String, Object?>{
          'peer_pubkey_hex': peerPubkeyHex,
          'updated_at': now,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
  }

  @override
  Future<Set<String>> loadSuppressedContacts() async {
    final rows = await _db.query(
      MainDatabaseSchema.suppressedContactsTable,
      columns: <String>['peer_pubkey_hex'],
      orderBy: 'peer_pubkey_hex ASC',
    );
    return rows
        .map((row) => (row['peer_pubkey_hex'] as String? ?? '').trim())
        .where((value) => value.isNotEmpty)
        .toSet();
  }

  @override
  Future<void> saveChatUiState(MainDatabaseChatUiStateRecord state) async {
    final encrypted = await _cipher.encryptJson(<String, dynamic>{
      'scrollOffset': state.scrollOffset,
    });
    await _db.insert(
      MainDatabaseSchema.chatUiStateTable,
      <String, Object?>{
        'room_uuid': state.roomUuid,
        'updated_at': state.updatedAtMs,
        'nonce': encrypted.nonce,
        'ciphertext': encrypted.ciphertext,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  @override
  Future<MainDatabaseChatUiStateRecord?> loadChatUiState(String roomUuid) async {
    final rows = await _db.query(
      MainDatabaseSchema.chatUiStateTable,
      where: 'room_uuid = ?',
      whereArgs: <Object?>[roomUuid],
      limit: 1,
    );
    final row = rows.isEmpty ? null : rows.first;
    if (row == null) return null;
    final payload = await _decryptRow(row);
    return MainDatabaseChatUiStateRecord(
      roomUuid: row['room_uuid'] as String? ?? '',
      scrollOffset: (payload['scrollOffset'] as num?)?.toDouble() ?? 0,
      updatedAtMs: (row['updated_at'] as num?)?.toInt() ?? 0,
    );
  }

  @override
  Future<void> saveChatMetadata({
    required String roomUuid,
    required String serverAddress,
    required int updatedAtMs,
    required Map<String, dynamic> payload,
  }) async {
    final encrypted = await _cipher.encryptJson(payload);
    await _db.insert(
      MainDatabaseSchema.chatMetadataTable,
      <String, Object?>{
        'room_uuid': roomUuid,
        'server_address': serverAddress,
        'updated_at': updatedAtMs,
        'nonce': encrypted.nonce,
        'ciphertext': encrypted.ciphertext,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  @override
  Future<MainDatabaseChatMetadataRecord?> loadChatMetadata(
    String roomUuid, {
    String? serverAddress,
  }) async {
    final hasServer = serverAddress != null && serverAddress.trim().isNotEmpty;
    final rows = await _db.query(
      MainDatabaseSchema.chatMetadataTable,
      where: hasServer
          ? 'room_uuid = ? AND server_address = ?'
          : 'room_uuid = ?',
      whereArgs: hasServer
          ? <Object?>[roomUuid, serverAddress.trim()]
          : <Object?>[roomUuid],
      orderBy: 'updated_at DESC',
      limit: 1,
    );
    final row = rows.isEmpty ? null : rows.first;
    if (row == null) return null;
    return MainDatabaseChatMetadataRecord(
      roomUuid: row['room_uuid'] as String? ?? '',
      serverAddress: row['server_address'] as String? ?? '',
      updatedAtMs: (row['updated_at'] as num?)?.toInt() ?? 0,
      payload: await _decryptRow(row),
    );
  }

  @override
  Future<List<MainDatabaseChatMetadataRecord>> loadAllChatMetadata() async {
    final rows = await _db.query(
      MainDatabaseSchema.chatMetadataTable,
      orderBy: 'updated_at DESC',
    );
    final out = <MainDatabaseChatMetadataRecord>[];
    for (final row in rows) {
      out.add(
        MainDatabaseChatMetadataRecord(
          roomUuid: row['room_uuid'] as String? ?? '',
          serverAddress: row['server_address'] as String? ?? '',
          updatedAtMs: (row['updated_at'] as num?)?.toInt() ?? 0,
          payload: await _decryptRow(row),
        ),
      );
    }
    return out;
  }

  @override
  Future<void> deleteChatMetadata(
    String roomUuid, {
    String? serverAddress,
  }) {
    final hasServer = serverAddress != null && serverAddress.trim().isNotEmpty;
    return _db.delete(
      MainDatabaseSchema.chatMetadataTable,
      where: hasServer
          ? 'room_uuid = ? AND server_address = ?'
          : 'room_uuid = ?',
      whereArgs: hasServer
          ? <Object?>[roomUuid, serverAddress.trim()]
          : <Object?>[roomUuid],
    );
  }

  @override
  Future<int> countChatHistory(String roomUuid) async {
    final row = await _db.rawQuery(
      '''
SELECT COUNT(*) AS cnt
FROM ${MainDatabaseSchema.chatHistoryTable}
WHERE room_uuid = ?
''',
      <Object?>[roomUuid],
    );
    final first = row.isEmpty ? null : row.first;
    return (first?['cnt'] as num?)?.toInt() ?? 0;
  }

  @override
  Future<int> appendChatHistoryIfAbsent({
    required String roomUuid,
    required String messageId,
    required int timestampMs,
    required Map<String, dynamic> payload,
  }) async {
    final encrypted = await _cipher.encryptJson(payload);
    return _db.insert(
      MainDatabaseSchema.chatHistoryTable,
      <String, Object?>{
        'room_uuid': roomUuid,
        'message_id': messageId,
        'timestamp_ms': timestampMs,
        'nonce': encrypted.nonce,
        'ciphertext': encrypted.ciphertext,
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  @override
  Future<List<MainDatabaseChatHistoryRecord>> readChatHistoryRange({
    required String roomUuid,
    required int offset,
    required int limit,
  }) async {
    if (limit <= 0) return const [];
    final rows = await _db.query(
      MainDatabaseSchema.chatHistoryTable,
      where: 'room_uuid = ?',
      whereArgs: <Object?>[roomUuid],
      orderBy: 'timestamp_ms ASC, message_id ASC',
      limit: limit,
      offset: offset,
    );
    final out = <MainDatabaseChatHistoryRecord>[];
    for (final row in rows) {
      out.add(
        MainDatabaseChatHistoryRecord(
          roomUuid: row['room_uuid'] as String? ?? '',
          messageId: row['message_id'] as String? ?? '',
          timestampMs: (row['timestamp_ms'] as num?)?.toInt() ?? 0,
          payload: await _decryptRow(row),
        ),
      );
    }
    return out;
  }

  @override
  Future<void> clearChatHistory(String roomUuid) {
    return _db.delete(
      MainDatabaseSchema.chatHistoryTable,
      where: 'room_uuid = ?',
      whereArgs: <Object?>[roomUuid],
    );
  }

  Future<Map<String, dynamic>> _decryptRow(Map<String, Object?> row) {
    final nonce = row['nonce'];
    final ciphertext = row['ciphertext'];
    return _cipher.decryptJson(
      nonce: Uint8List.fromList(List<int>.from(nonce as List)),
      ciphertext: Uint8List.fromList(List<int>.from(ciphertext as List)),
    );
  }

  Future<MainDatabaseContactProfileRecord?> _mapContactProfileRow(
    Map<String, Object?> row,
  ) async {
    final payload = await _decryptRow(row);
    final avatarB64 = payload['avatarB64'] as String?;
    Uint8List? avatarBytes;
    if (avatarB64 != null && avatarB64.isNotEmpty) {
      try {
        avatarBytes = Uint8List.fromList(base64Decode(avatarB64));
      } catch (_) {
        avatarBytes = null;
      }
    }
    return MainDatabaseContactProfileRecord(
      peerPubkeyHex: row['peer_pubkey_hex'] as String? ?? '',
      username: payload['username'] as String?,
      fullname: payload['fullname'] as String?,
      avatarBytes: avatarBytes,
      avatarSha256Hex: payload['avatarSha256Hex'] as String? ?? '',
      updatedAtMs: (row['updated_at'] as num?)?.toInt() ?? 0,
    );
  }
}
