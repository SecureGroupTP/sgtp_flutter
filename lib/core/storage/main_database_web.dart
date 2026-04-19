import 'dart:convert';
import 'dart:typed_data';

import 'package:idb_shim/idb_browser.dart';

import 'main_database.dart';
import 'main_database_schema.dart';

const _settingsStoreName = 'settings_records';
const _contactEntriesStoreName = 'contact_entries';
const _contactProfilesStoreName = 'contact_profiles';
const _friendStatesStoreName = 'friend_states';
const _suppressedContactsStoreName = 'suppressed_contacts';
const _chatUiStateStoreName = 'chat_ui_state_records';
const _chatMetadataStoreName = 'chat_metadata_records';
const _chatHistoryStoreName = 'chat_history_records';

Future<MainDatabase> openMainDatabase({
  required String accountId,
  required String databaseName,
  required String databasePath,
  required Uint8List encryptionKey,
}) async {
  final idbFactory = getIdbFactory();
  if (idbFactory == null) {
    throw UnsupportedError('IndexedDB is not available');
  }
  final db = await idbFactory.open(
    databaseName,
    version: MainDatabaseSchema.currentVersion,
    onUpgradeNeeded: (event) {
      final db = event.database;
      if (!db.objectStoreNames.contains(_settingsStoreName)) {
        db.createObjectStore(_settingsStoreName);
      }
      if (!db.objectStoreNames.contains(_contactEntriesStoreName)) {
        db.createObjectStore(_contactEntriesStoreName);
      }
      if (!db.objectStoreNames.contains(_contactProfilesStoreName)) {
        db.createObjectStore(_contactProfilesStoreName);
      }
      if (!db.objectStoreNames.contains(_friendStatesStoreName)) {
        db.createObjectStore(_friendStatesStoreName);
      }
      if (!db.objectStoreNames.contains(_suppressedContactsStoreName)) {
        db.createObjectStore(_suppressedContactsStoreName);
      }
      if (!db.objectStoreNames.contains(_chatUiStateStoreName)) {
        db.createObjectStore(_chatUiStateStoreName);
      }
      if (!db.objectStoreNames.contains(_chatMetadataStoreName)) {
        db.createObjectStore(_chatMetadataStoreName);
      }
      if (!db.objectStoreNames.contains(_chatHistoryStoreName)) {
        db.createObjectStore(_chatHistoryStoreName);
      }
    },
  );
  return _WebMainDatabase(
    db: db,
    cipher: MainDatabaseCipher(encryptionKey),
  );
}

Future<void> deleteMainDatabase({
  required String accountId,
  required String databaseName,
  required String databasePath,
}) async {
  final idbFactory = getIdbFactory();
  if (idbFactory == null) return;
  await idbFactory.deleteDatabase(databaseName);
}

class _WebMainDatabase implements MainDatabase {
  _WebMainDatabase({
    required Database db,
    required MainDatabaseCipher cipher,
  })  : _db = db,
        _cipher = cipher;

  final Database _db;
  final MainDatabaseCipher _cipher;

  @override
  Future<void> close() async => _db.close();

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
    final txn = _db.transaction(_settingsStoreName, idbModeReadWrite);
    final store = txn.objectStore(_settingsStoreName);
    await store.put(_encodeEncryptedRecord(encrypted), key);
    await txn.completed;
  }

  @override
  Future<Map<String, dynamic>?> loadSettingJson(String key) async {
    final txn = _db.transaction(_settingsStoreName, idbModeReadOnly);
    final store = txn.objectStore(_settingsStoreName);
    final raw = await store.getObject(key);
    await txn.completed;
    if (raw is! Map) return null;
    return _decryptRecord(Map<String, dynamic>.from(raw));
  }

  @override
  Future<void> deleteSetting(String key) async {
    final txn = _db.transaction(_settingsStoreName, idbModeReadWrite);
    final store = txn.objectStore(_settingsStoreName);
    await store.delete(key);
    await txn.completed;
  }

  @override
  Future<void> replaceContactEntries(
    List<MainDatabaseContactEntryRecord> entries,
  ) async {
    final txn = _db.transaction(_contactEntriesStoreName, idbModeReadWrite);
    final store = txn.objectStore(_contactEntriesStoreName);
    await store.clear();
    for (final entry in entries) {
      final encrypted = await _cipher.encryptJson(<String, dynamic>{
        'peerPubkeyB64': base64Encode(entry.peerPubkeyBytes),
        'displayName': entry.displayName,
      });
      await store.put(
        <String, Object?>{
          'peerPubkeyHex': entry.peerPubkeyHex,
          'updatedAtMs': entry.updatedAtMs,
          ..._encodeEncryptedRecord(encrypted),
        },
        entry.peerPubkeyHex,
      );
    }
    await txn.completed;
  }

  @override
  Future<List<MainDatabaseContactEntryRecord>> loadContactEntries() async {
    final txn = _db.transaction(_contactEntriesStoreName, idbModeReadOnly);
    final store = txn.objectStore(_contactEntriesStoreName);
    final values = <Map<String, dynamic>>[];
    await store.openCursor(autoAdvance: true).forEach((cursor) {
      final value = cursor.value;
      if (value is Map) {
        values.add(Map<String, dynamic>.from(value));
      }
    });
    await txn.completed;
    final out = <MainDatabaseContactEntryRecord>[];
    for (final value in values) {
      final payload = await _decryptRecord(value);
      final peerPubkeyB64 = payload['peerPubkeyB64'] as String? ?? '';
      Uint8List peerPubkeyBytes;
      try {
        peerPubkeyBytes = Uint8List.fromList(base64Decode(peerPubkeyB64));
      } catch (_) {
        continue;
      }
      out.add(
        MainDatabaseContactEntryRecord(
          peerPubkeyHex: value['peerPubkeyHex'] as String? ?? '',
          peerPubkeyBytes: peerPubkeyBytes,
          displayName: payload['displayName'] as String? ?? 'unknown',
          updatedAtMs: (value['updatedAtMs'] as num?)?.toInt() ?? 0,
        ),
      );
    }
    out.sort((a, b) {
      final updatedCompare = b.updatedAtMs.compareTo(a.updatedAtMs);
      if (updatedCompare != 0) return updatedCompare;
      return a.peerPubkeyHex.compareTo(b.peerPubkeyHex);
    });
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
    final txn = _db.transaction(_contactProfilesStoreName, idbModeReadWrite);
    final store = txn.objectStore(_contactProfilesStoreName);
    await store.put(
      <String, Object?>{
        'peerPubkeyHex': profile.peerPubkeyHex,
        'updatedAtMs': profile.updatedAtMs,
        ..._encodeEncryptedRecord(encrypted),
      },
      profile.peerPubkeyHex,
    );
    await txn.completed;
  }

  @override
  Future<MainDatabaseContactProfileRecord?> loadContactProfile(
    String peerPubkeyHex,
  ) async {
    final txn = _db.transaction(_contactProfilesStoreName, idbModeReadOnly);
    final store = txn.objectStore(_contactProfilesStoreName);
    final raw = await store.getObject(peerPubkeyHex);
    await txn.completed;
    if (raw is! Map) return null;
    return _mapContactProfileRecord(Map<String, dynamic>.from(raw));
  }

  @override
  Future<List<MainDatabaseContactProfileRecord>> loadAllContactProfiles() async {
    final txn = _db.transaction(_contactProfilesStoreName, idbModeReadOnly);
    final store = txn.objectStore(_contactProfilesStoreName);
    final values = <Map<String, dynamic>>[];
    await store.openCursor(autoAdvance: true).forEach((cursor) {
      final value = cursor.value;
      if (value is Map) {
        values.add(Map<String, dynamic>.from(value));
      }
    });
    await txn.completed;
    final out = <MainDatabaseContactProfileRecord>[];
    for (final value in values) {
      final mapped = await _mapContactProfileRecord(value);
      if (mapped != null) {
        out.add(mapped);
      }
    }
    out.sort((a, b) {
      final updatedCompare = b.updatedAtMs.compareTo(a.updatedAtMs);
      if (updatedCompare != 0) return updatedCompare;
      return a.peerPubkeyHex.compareTo(b.peerPubkeyHex);
    });
    return out;
  }

  @override
  Future<void> replaceFriendStates(
    List<MainDatabaseFriendStateRecord> states,
  ) async {
    final txn = _db.transaction(_friendStatesStoreName, idbModeReadWrite);
    final store = txn.objectStore(_friendStatesStoreName);
    await store.clear();
    for (final state in states) {
      final encrypted = await _cipher.encryptJson(<String, dynamic>{
        'status': state.status,
        'roomUuidHex': state.roomUuidHex,
      });
      await store.put(
        <String, Object?>{
          'peerPubkeyHex': state.peerPubkeyHex,
          'updatedAtMs': state.updatedAtMs,
          ..._encodeEncryptedRecord(encrypted),
        },
        state.peerPubkeyHex,
      );
    }
    await txn.completed;
  }

  @override
  Future<List<MainDatabaseFriendStateRecord>> loadFriendStates() async {
    final txn = _db.transaction(_friendStatesStoreName, idbModeReadOnly);
    final store = txn.objectStore(_friendStatesStoreName);
    final values = <Map<String, dynamic>>[];
    await store.openCursor(autoAdvance: true).forEach((cursor) {
      final value = cursor.value;
      if (value is Map) {
        values.add(Map<String, dynamic>.from(value));
      }
    });
    await txn.completed;
    final out = <MainDatabaseFriendStateRecord>[];
    for (final value in values) {
      final payload = await _decryptRecord(value);
      out.add(
        MainDatabaseFriendStateRecord(
          peerPubkeyHex: value['peerPubkeyHex'] as String? ?? '',
          status: payload['status'] as String? ?? '',
          roomUuidHex: (payload['roomUuidHex'] as String?)?.trim(),
          updatedAtMs: (value['updatedAtMs'] as num?)?.toInt() ?? 0,
        ),
      );
    }
    out.sort((a, b) {
      final updatedCompare = b.updatedAtMs.compareTo(a.updatedAtMs);
      if (updatedCompare != 0) return updatedCompare;
      return a.peerPubkeyHex.compareTo(b.peerPubkeyHex);
    });
    return out;
  }

  @override
  Future<void> replaceSuppressedContacts(Set<String> peerPubkeyHexes) async {
    final txn = _db.transaction(_suppressedContactsStoreName, idbModeReadWrite);
    final store = txn.objectStore(_suppressedContactsStoreName);
    await store.clear();
    final updatedAtMs = DateTime.now().millisecondsSinceEpoch;
    for (final peerPubkeyHex in peerPubkeyHexes) {
      await store.put(
        <String, Object?>{
          'peerPubkeyHex': peerPubkeyHex,
          'updatedAtMs': updatedAtMs,
        },
        peerPubkeyHex,
      );
    }
    await txn.completed;
  }

  @override
  Future<Set<String>> loadSuppressedContacts() async {
    final txn = _db.transaction(_suppressedContactsStoreName, idbModeReadOnly);
    final store = txn.objectStore(_suppressedContactsStoreName);
    final out = <String>{};
    await store.openCursor(autoAdvance: true).forEach((cursor) {
      final value = cursor.value;
      if (value is Map) {
        final hex = (value['peerPubkeyHex'] as String? ?? '').trim();
        if (hex.isNotEmpty) {
          out.add(hex);
        }
      }
    });
    await txn.completed;
    return out;
  }

  @override
  Future<void> saveChatUiState(MainDatabaseChatUiStateRecord state) async {
    final encrypted = await _cipher.encryptJson(<String, dynamic>{
      'scrollOffset': state.scrollOffset,
    });
    final txn = _db.transaction(_chatUiStateStoreName, idbModeReadWrite);
    final store = txn.objectStore(_chatUiStateStoreName);
    await store.put(
      <String, Object?>{
        'roomUuid': state.roomUuid,
        'updatedAtMs': state.updatedAtMs,
        ..._encodeEncryptedRecord(encrypted),
      },
      state.roomUuid,
    );
    await txn.completed;
  }

  @override
  Future<MainDatabaseChatUiStateRecord?> loadChatUiState(String roomUuid) async {
    final txn = _db.transaction(_chatUiStateStoreName, idbModeReadOnly);
    final store = txn.objectStore(_chatUiStateStoreName);
    final raw = await store.getObject(roomUuid);
    await txn.completed;
    if (raw is! Map) return null;
    final value = Map<String, dynamic>.from(raw);
    final payload = await _decryptRecord(value);
    return MainDatabaseChatUiStateRecord(
      roomUuid: value['roomUuid'] as String? ?? '',
      scrollOffset: (payload['scrollOffset'] as num?)?.toDouble() ?? 0,
      updatedAtMs: (value['updatedAtMs'] as num?)?.toInt() ?? 0,
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
    final txn = _db.transaction(_chatMetadataStoreName, idbModeReadWrite);
    final store = txn.objectStore(_chatMetadataStoreName);
    await store.put(
      <String, Object?>{
        'roomUuid': roomUuid,
        'serverAddress': serverAddress,
        'updatedAtMs': updatedAtMs,
        ..._encodeEncryptedRecord(encrypted),
      },
      _chatMetadataKey(roomUuid, serverAddress),
    );
    await txn.completed;
  }

  @override
  Future<MainDatabaseChatMetadataRecord?> loadChatMetadata(
    String roomUuid, {
    String? serverAddress,
  }) async {
    final all = await loadAllChatMetadata();
    if (serverAddress != null && serverAddress.trim().isNotEmpty) {
      for (final record in all) {
        if (record.roomUuid == roomUuid &&
            record.serverAddress == serverAddress.trim()) {
          return record;
        }
      }
      return null;
    }
    for (final record in all) {
      if (record.roomUuid == roomUuid) return record;
    }
    return null;
  }

  @override
  Future<List<MainDatabaseChatMetadataRecord>> loadAllChatMetadata() async {
    final txn = _db.transaction(_chatMetadataStoreName, idbModeReadOnly);
    final store = txn.objectStore(_chatMetadataStoreName);
    final values = <Map<String, dynamic>>[];
    await store.openCursor(autoAdvance: true).forEach((cursor) {
      final value = cursor.value;
      if (value is Map) {
        values.add(Map<String, dynamic>.from(value));
      }
    });
    await txn.completed;
    final out = <MainDatabaseChatMetadataRecord>[];
    for (final value in values) {
      out.add(
        MainDatabaseChatMetadataRecord(
          roomUuid: value['roomUuid'] as String? ?? '',
          serverAddress: value['serverAddress'] as String? ?? '',
          updatedAtMs: (value['updatedAtMs'] as num?)?.toInt() ?? 0,
          payload: await _decryptRecord(value),
        ),
      );
    }
    out.sort((a, b) => b.updatedAtMs.compareTo(a.updatedAtMs));
    return out;
  }

  @override
  Future<void> deleteChatMetadata(
    String roomUuid, {
    String? serverAddress,
  }) async {
    final txn = _db.transaction(_chatMetadataStoreName, idbModeReadWrite);
    final store = txn.objectStore(_chatMetadataStoreName);
    if (serverAddress != null && serverAddress.trim().isNotEmpty) {
      await store.delete(_chatMetadataKey(roomUuid, serverAddress.trim()));
      await txn.completed;
      return;
    }

    final keys = <Object>[];
    await store.openCursor(autoAdvance: true).forEach((cursor) {
      final value = cursor.value;
      if (value is Map && (value['roomUuid'] as String? ?? '') == roomUuid) {
        final key = cursor.key;
        if (key != null) {
          keys.add(key);
        }
      }
    });
    for (final key in keys) {
      await store.delete(key);
    }
    await txn.completed;
  }

  @override
  Future<int> countChatHistory(String roomUuid) async {
    final all = await _loadAllHistoryValues();
    return all.where((value) => value['roomUuid'] == roomUuid).length;
  }

  @override
  Future<int> appendChatHistoryIfAbsent({
    required String roomUuid,
    required String messageId,
    required int timestampMs,
    required Map<String, dynamic> payload,
  }) async {
    final txn = _db.transaction(_chatHistoryStoreName, idbModeReadWrite);
    final store = txn.objectStore(_chatHistoryStoreName);
    final key = _chatHistoryKey(roomUuid, messageId);
    final existing = await store.getObject(key);
    if (existing != null) {
      await txn.completed;
      return 0;
    }
    final encrypted = await _cipher.encryptJson(payload);
    await store.put(
      <String, Object?>{
        'roomUuid': roomUuid,
        'messageId': messageId,
        'timestampMs': timestampMs,
        ..._encodeEncryptedRecord(encrypted),
      },
      key,
    );
    await txn.completed;
    return 1;
  }

  @override
  Future<List<MainDatabaseChatHistoryRecord>> readChatHistoryRange({
    required String roomUuid,
    required int offset,
    required int limit,
  }) async {
    if (limit <= 0) return const [];
    final all = await _loadAllHistoryValues();
    final filtered = all
        .where((value) => value['roomUuid'] == roomUuid)
        .toList()
      ..sort((a, b) {
        final leftTs = (a['timestampMs'] as num?)?.toInt() ?? 0;
        final rightTs = (b['timestampMs'] as num?)?.toInt() ?? 0;
        final tsCompare = leftTs.compareTo(rightTs);
        if (tsCompare != 0) return tsCompare;
        final leftId = a['messageId'] as String? ?? '';
        final rightId = b['messageId'] as String? ?? '';
        return leftId.compareTo(rightId);
      });
    final slice = filtered.skip(offset).take(limit);
    final out = <MainDatabaseChatHistoryRecord>[];
    for (final value in slice) {
      out.add(
        MainDatabaseChatHistoryRecord(
          roomUuid: value['roomUuid'] as String? ?? '',
          messageId: value['messageId'] as String? ?? '',
          timestampMs: (value['timestampMs'] as num?)?.toInt() ?? 0,
          payload: await _decryptRecord(value),
        ),
      );
    }
    return out;
  }

  @override
  Future<void> clearChatHistory(String roomUuid) async {
    final txn = _db.transaction(_chatHistoryStoreName, idbModeReadWrite);
    final store = txn.objectStore(_chatHistoryStoreName);
    final keys = <Object>[];
    await store.openCursor(autoAdvance: true).forEach((cursor) {
      final value = cursor.value;
      if (value is Map && (value['roomUuid'] as String? ?? '') == roomUuid) {
        final key = cursor.key;
        if (key != null) {
          keys.add(key);
        }
      }
    });
    for (final key in keys) {
      await store.delete(key);
    }
    await txn.completed;
  }

  Map<String, Object?> _encodeEncryptedRecord(
    MainDatabaseEncryptedValue encrypted,
  ) {
    return <String, Object?>{
      'nonce': base64Encode(encrypted.nonce),
      'ciphertext': base64Encode(encrypted.ciphertext),
    };
  }

  Future<Map<String, dynamic>> _decryptRecord(Map<String, dynamic> value) {
    return _cipher.decryptJson(
      nonce: Uint8List.fromList(base64Decode(value['nonce'] as String? ?? '')),
      ciphertext: Uint8List.fromList(
        base64Decode(value['ciphertext'] as String? ?? ''),
      ),
    );
  }

  Future<MainDatabaseContactProfileRecord?> _mapContactProfileRecord(
    Map<String, dynamic> value,
  ) async {
    final payload = await _decryptRecord(value);
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
      peerPubkeyHex: value['peerPubkeyHex'] as String? ?? '',
      username: payload['username'] as String?,
      fullname: payload['fullname'] as String?,
      avatarBytes: avatarBytes,
      avatarSha256Hex: payload['avatarSha256Hex'] as String? ?? '',
      updatedAtMs: (value['updatedAtMs'] as num?)?.toInt() ?? 0,
    );
  }

  String _chatMetadataKey(String roomUuid, String serverAddress) =>
      '$serverAddress\u0000$roomUuid';

  String _chatHistoryKey(String roomUuid, String messageId) =>
      '$roomUuid\u0000$messageId';

  Future<List<Map<String, dynamic>>> _loadAllHistoryValues() async {
    final txn = _db.transaction(_chatHistoryStoreName, idbModeReadOnly);
    final store = txn.objectStore(_chatHistoryStoreName);
    final values = <Map<String, dynamic>>[];
    await store.openCursor(autoAdvance: true).forEach((cursor) {
      final value = cursor.value;
      if (value is Map) {
        values.add(Map<String, dynamic>.from(value));
      }
    });
    await txn.completed;
    return values;
  }
}
