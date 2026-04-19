import 'dart:convert';
import 'dart:typed_data';

import 'package:sgtp_flutter/core/app_log.dart';
import 'package:sgtp_flutter/core/storage/main_database.dart';
import 'package:sgtp_flutter/core/storage/main_database_factory.dart';
import 'package:sgtp_flutter/features/messaging/domain/entities/chat_metadata.dart';

final _log = AppLog('ChatMetadataRepository');

class ChatMetadataRepository {
  ChatMetadataRepository({
    required String? accountId,
    required MainDatabaseFactory mainDatabaseFactory,
  })  : _accountId = (accountId ?? '').trim(),
        _mainDatabaseFactory = mainDatabaseFactory;

  final String _accountId;
  final MainDatabaseFactory _mainDatabaseFactory;

  Future<MainDatabase> _db() => _mainDatabaseFactory.openForAccount(_accountId);

  Future<List<ChatMetadata>> loadAllChats() async {
    final db = await _db();
    final records = await db.loadAllChatMetadata();
    return records
        .map(
          (record) => _fromPayload(
            record.roomUuid,
            record.serverAddress,
            record.payload,
          ),
        )
        .toList(growable: false);
  }

  Future<ChatMetadata?> loadChat(String uuid, {String? serverAddress}) async {
    final db = await _db();
    final record = await db.loadChatMetadata(
      uuid,
      serverAddress: serverAddress?.trim(),
    );
    if (record == null) return null;
    return _fromPayload(record.roomUuid, record.serverAddress, record.payload);
  }

  Future<void> saveChat(ChatMetadata metadata) async {
    final db = await _db();
    await db.saveChatMetadata(
      roomUuid: metadata.uuid,
      serverAddress: metadata.serverAddress.trim(),
      updatedAtMs: metadata.updatedAt.millisecondsSinceEpoch,
      payload: _toPayload(metadata),
    );
    _log.info('[ChatMetadata] Saved chat: {uuid}@{server}', parameters: {
      'uuid': metadata.uuid,
      'server': metadata.serverAddress,
    });
  }

  Future<void> updateChat(ChatMetadata metadata) async {
    final updated = metadata.copyWith(updatedAt: DateTime.now());
    await saveChat(updated);
  }

  Future<void> deleteChat(String uuid, {String? serverAddress}) async {
    final db = await _db();
    await db.deleteChatMetadata(uuid, serverAddress: serverAddress?.trim());
    _log.info('[ChatMetadata] Deleted chat: {uuid}{suffix}', parameters: {
      'uuid': uuid,
      'suffix': serverAddress != null && serverAddress.trim().isNotEmpty
          ? '@${serverAddress.trim()}'
          : '',
    });
  }

  Map<String, dynamic> _toPayload(ChatMetadata metadata) {
    return <String, dynamic>{
      'uuid': metadata.uuid,
      'name': metadata.name,
      'serverAddress': metadata.serverAddress.trim(),
      'remoteRoomId': metadata.remoteRoomId,
      'avatarB64': metadata.avatarBytes != null
          ? base64Encode(metadata.avatarBytes!)
          : null,
      'isDirectMessage': metadata.isDirectMessage,
      'createdAt': metadata.createdAt.toIso8601String(),
      'updatedAt': metadata.updatedAt.toIso8601String(),
      'windowWidth': metadata.windowWidth,
      'windowHeight': metadata.windowHeight,
    };
  }

  ChatMetadata _fromPayload(
    String uuid,
    String serverAddress,
    Map<String, dynamic> payload,
  ) {
    Uint8List? avatarBytes;
    final avatarB64 = payload['avatarB64'] as String?;
    if (avatarB64 != null && avatarB64.isNotEmpty) {
      try {
        avatarBytes = base64Decode(avatarB64);
      } catch (_) {}
    }
    return ChatMetadata(
      uuid: uuid,
      name: payload['name'] as String? ?? 'Chat',
      serverAddress:
          (payload['serverAddress'] as String? ?? serverAddress).trim(),
      remoteRoomId: (payload['remoteRoomId'] as String?)?.trim(),
      avatarBytes: avatarBytes,
      isDirectMessage: payload['isDirectMessage'] as bool? ?? false,
      createdAt: DateTime.tryParse(payload['createdAt'] as String? ?? '') ??
          DateTime.now(),
      updatedAt: DateTime.tryParse(payload['updatedAt'] as String? ?? '') ??
          DateTime.now(),
      windowWidth: (payload['windowWidth'] as num?)?.toInt(),
      windowHeight: (payload['windowHeight'] as num?)?.toInt(),
    );
  }
}
