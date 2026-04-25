import 'dart:convert';
import 'dart:typed_data';

import 'package:sgtp_flutter/core/storage/main_database.dart';
import 'package:sgtp_flutter/core/storage/main_database_factory.dart';

class PersistedHistoryRecord {
  final Uint8List senderUUID;
  final Uint8List messageUUID;
  final int timestamp;
  final int nonce;
  final Uint8List plaintext;

  const PersistedHistoryRecord({
    required this.senderUUID,
    required this.messageUUID,
    required this.timestamp,
    required this.nonce,
    required this.plaintext,
  });

  String get messageIdHex =>
      messageUUID.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  Map<String, dynamic> toJson() => {
        'senderUUID': base64.encode(senderUUID),
        'messageUUID': base64.encode(messageUUID),
        'timestamp': timestamp,
        'nonce': nonce,
        'plaintext': base64.encode(plaintext),
      };

  static PersistedHistoryRecord fromJson(Map<String, dynamic> json) {
    return PersistedHistoryRecord(
      senderUUID: base64.decode(json['senderUUID'] as String? ?? ''),
      messageUUID: base64.decode(json['messageUUID'] as String? ?? ''),
      timestamp: (json['timestamp'] as num?)?.toInt() ?? 0,
      nonce: (json['nonce'] as num?)?.toInt() ?? 0,
      plaintext: base64.decode(json['plaintext'] as String? ?? ''),
    );
  }
}

class ChatHistoryRepository {
  ChatHistoryRepository({
    required this.accountId,
    required this.serverAddress,
    required this.chatUUID,
    required MainDatabaseFactory mainDatabaseFactory,
  }) : _mainDatabaseFactory = mainDatabaseFactory;

  final String accountId;
  final String serverAddress;
  final String chatUUID;
  final MainDatabaseFactory _mainDatabaseFactory;

  Future<MainDatabase> _db() => _mainDatabaseFactory.openForAccount(accountId);

  Future<int> count() async {
    final db = await _db();
    return db.countChatHistory(_historyRoomKey);
  }

  Future<int> appendIfAbsent(PersistedHistoryRecord record) async {
    final db = await _db();
    return db.appendChatHistoryIfAbsent(
      roomUuid: _historyRoomKey,
      messageId: record.messageIdHex,
      timestampMs: record.timestamp,
      payload: record.toJson(),
    );
  }

  Future<List<PersistedHistoryRecord>> readRange({
    required int offset,
    required int limit,
  }) async {
    final db = await _db();
    final records = await db.readChatHistoryRange(
      roomUuid: _historyRoomKey,
      offset: offset,
      limit: limit,
    );
    return records
        .map((record) => PersistedHistoryRecord.fromJson(record.payload))
        .toList(growable: false);
  }

  Future<List<PersistedHistoryRecord>> readBatchFromEnd({
    required int offsetFromEnd,
    int limit = 100,
  }) async {
    final total = await count();
    if (total <= 0 || limit <= 0 || offsetFromEnd < 0) return const [];
    final endExclusive = total - offsetFromEnd;
    if (endExclusive <= 0) return const [];
    final start = (endExclusive - limit).clamp(0, endExclusive);
    return readRange(offset: start, limit: endExclusive - start);
  }

  Future<void> clear() async {
    final db = await _db();
    await db.clearChatHistory(_historyRoomKey);
  }

  String get _historyRoomKey {
    final normalizedServer = serverAddress.trim().toLowerCase();
    return '$normalizedServer|${chatUUID.trim()}';
  }
}
