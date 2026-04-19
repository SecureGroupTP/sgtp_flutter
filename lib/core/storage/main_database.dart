import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

class MainDatabaseChatMetadataRecord {
  const MainDatabaseChatMetadataRecord({
    required this.roomUuid,
    required this.serverAddress,
    required this.updatedAtMs,
    required this.payload,
  });

  final String roomUuid;
  final String serverAddress;
  final int updatedAtMs;
  final Map<String, dynamic> payload;
}

class MainDatabaseChatHistoryRecord {
  const MainDatabaseChatHistoryRecord({
    required this.roomUuid,
    required this.messageId,
    required this.timestampMs,
    required this.payload,
  });

  final String roomUuid;
  final String messageId;
  final int timestampMs;
  final Map<String, dynamic> payload;
}

class MainDatabaseContactEntryRecord {
  const MainDatabaseContactEntryRecord({
    required this.peerPubkeyHex,
    required this.peerPubkeyBytes,
    required this.displayName,
    required this.updatedAtMs,
  });

  final String peerPubkeyHex;
  final Uint8List peerPubkeyBytes;
  final String displayName;
  final int updatedAtMs;
}

class MainDatabaseContactProfileRecord {
  const MainDatabaseContactProfileRecord({
    required this.peerPubkeyHex,
    required this.username,
    required this.fullname,
    required this.avatarBytes,
    required this.avatarSha256Hex,
    required this.updatedAtMs,
  });

  final String peerPubkeyHex;
  final String? username;
  final String? fullname;
  final Uint8List? avatarBytes;
  final String avatarSha256Hex;
  final int updatedAtMs;
}

class MainDatabaseFriendStateRecord {
  const MainDatabaseFriendStateRecord({
    required this.peerPubkeyHex,
    required this.status,
    required this.roomUuidHex,
    required this.updatedAtMs,
  });

  final String peerPubkeyHex;
  final String status;
  final String? roomUuidHex;
  final int updatedAtMs;
}

class MainDatabaseChatUiStateRecord {
  const MainDatabaseChatUiStateRecord({
    required this.roomUuid,
    required this.scrollOffset,
    required this.updatedAtMs,
  });

  final String roomUuid;
  final double scrollOffset;
  final int updatedAtMs;
}

class MainDatabaseEncryptedValue {
  const MainDatabaseEncryptedValue({
    required this.nonce,
    required this.ciphertext,
  });

  final Uint8List nonce;
  final Uint8List ciphertext;
}

class MainDatabaseCipher {
  MainDatabaseCipher(Uint8List keyBytes)
      : _secretKey = SecretKey(Uint8List.fromList(keyBytes));

  static final Cipher _cipher = AesGcm.with256bits();
  static final Random _random = Random.secure();
  final SecretKey _secretKey;

  Future<MainDatabaseEncryptedValue> encryptJson(
    Map<String, dynamic> payload,
  ) async {
    final plaintext = utf8.encode(jsonEncode(payload));
    final nonce = Uint8List.fromList(
      List<int>.generate(12, (_) => _random.nextInt(256)),
    );
    final box = await _cipher.encrypt(
      plaintext,
      secretKey: _secretKey,
      nonce: nonce,
    );
    return MainDatabaseEncryptedValue(
      nonce: Uint8List.fromList(box.nonce),
      ciphertext: Uint8List.fromList(
        <int>[
          ...box.cipherText,
          ...box.mac.bytes,
        ],
      ),
    );
  }

  Future<Map<String, dynamic>> decryptJson({
    required Uint8List nonce,
    required Uint8List ciphertext,
  }) async {
    if (ciphertext.length < 16) {
      throw const FormatException('Encrypted payload is too short');
    }
    final cipherTextBytes = ciphertext.sublist(0, ciphertext.length - 16);
    final macBytes = ciphertext.sublist(ciphertext.length - 16);
    final cleartext = await _cipher.decrypt(
      SecretBox(
        cipherTextBytes,
        nonce: nonce,
        mac: Mac(macBytes),
      ),
      secretKey: _secretKey,
    );
    final decoded = jsonDecode(utf8.decode(cleartext));
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Encrypted payload is not a JSON object');
    }
    return decoded;
  }
}

abstract class MainDatabase {
  Future<void> close();

  Future<void> saveSettingString(String key, String value);
  Future<String?> loadSettingString(String key);
  Future<void> saveSettingBytes(String key, Uint8List value);
  Future<Uint8List?> loadSettingBytes(String key);
  Future<void> upsertSettingJson(String key, Map<String, dynamic> value);
  Future<Map<String, dynamic>?> loadSettingJson(String key);
  Future<void> deleteSetting(String key);

  Future<void> replaceContactEntries(List<MainDatabaseContactEntryRecord> entries);
  Future<List<MainDatabaseContactEntryRecord>> loadContactEntries();
  Future<void> saveContactProfile(MainDatabaseContactProfileRecord profile);
  Future<MainDatabaseContactProfileRecord?> loadContactProfile(String peerPubkeyHex);
  Future<List<MainDatabaseContactProfileRecord>> loadAllContactProfiles();
  Future<void> replaceFriendStates(List<MainDatabaseFriendStateRecord> states);
  Future<List<MainDatabaseFriendStateRecord>> loadFriendStates();
  Future<void> replaceSuppressedContacts(Set<String> peerPubkeyHexes);
  Future<Set<String>> loadSuppressedContacts();
  Future<void> saveChatUiState(MainDatabaseChatUiStateRecord state);
  Future<MainDatabaseChatUiStateRecord?> loadChatUiState(String roomUuid);

  Future<void> saveChatMetadata({
    required String roomUuid,
    required String serverAddress,
    required int updatedAtMs,
    required Map<String, dynamic> payload,
  });
  Future<MainDatabaseChatMetadataRecord?> loadChatMetadata(
    String roomUuid, {
    String? serverAddress,
  });
  Future<List<MainDatabaseChatMetadataRecord>> loadAllChatMetadata();
  Future<void> deleteChatMetadata(
    String roomUuid, {
    String? serverAddress,
  });

  Future<int> countChatHistory(String roomUuid);
  Future<int> appendChatHistoryIfAbsent({
    required String roomUuid,
    required String messageId,
    required int timestampMs,
    required Map<String, dynamic> payload,
  });
  Future<List<MainDatabaseChatHistoryRecord>> readChatHistoryRange({
    required String roomUuid,
    required int offset,
    required int limit,
  });
  Future<void> clearChatHistory(String roomUuid);
}
