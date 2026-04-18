import 'dart:async';
import 'dart:typed_data';

import 'package:cross_file/cross_file.dart';

import 'package:sgtp_flutter/features/messaging/domain/entities/sgtp_config.dart';
import 'package:sgtp_flutter/features/messaging/domain/entities/video_note_metadata.dart';
import 'package:sgtp_flutter/features/messaging/domain/entities/sgtp_events.dart';

export 'package:sgtp_flutter/features/messaging/domain/entities/sgtp_events.dart';

typedef SgtpSessionFactory = ISgtpSession Function(SgtpConfig config);

abstract class ISgtpSession {
  String get roomUUIDHex;
  String get myUUIDHex;
  List<String> get peerUUIDs;
  Map<String, String> get peerPublicKeys;

  Stream<SgtpEvent> get events;

  Future<void> connect();
  Future<void> disconnect();
  Future<void> close();
  Future<void> probeConnection();

  void setUserAvatar(Uint8List? bytes);

  Future<void> sendMessage(
    String text, {
    String? replyToId,
    String? replyToContent,
    String? replyToSender,
  });
  Future<void> sendImage(Uint8List bytes, String name, String mime);
  Future<void> sendVideo(XFile xFile, String name, String mime);
  Future<void> sendVoice(Uint8List bytes, String mime);
  Future<void> sendVideoNote(Uint8List bytes, String mime);
  Future<void> sendVideoNoteFromXFile(
    XFile xFile,
    String mime, {
    VideoNoteMetadata? metadata,
  });
  Future<void> sendMessageRead(String messageId);
  void sendReaction(String messageId, String emoji, bool adding);
  Future<void> sendChatMeta(String name, Uint8List? avatarBytes);

  Future<PersistedHistoryBatchResult> replayPersistedHistoryBatch({
    required int offsetFromEnd,
    required int limit,
  });
}
