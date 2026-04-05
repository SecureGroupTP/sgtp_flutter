import 'dart:typed_data';

import 'package:sgtp_flutter/features/messaging/application/models/messaging_models.dart';

sealed class SgtpEvent {}

class SgtpConnecting extends SgtpEvent {}

class SgtpHandshaking extends SgtpEvent {}

class SgtpReady extends SgtpEvent {
  final bool isMaster;
  final String roomUUIDHex;
  SgtpReady({required this.isMaster, required this.roomUUIDHex});
}

class SgtpMessageReceived extends SgtpEvent {
  final ChatMessage message;
  SgtpMessageReceived({required this.message});
}

class SgtpPeerJoined extends SgtpEvent {
  final String peerUUID;
  final String ed25519PubHex;
  SgtpPeerJoined({required this.peerUUID, required this.ed25519PubHex});
}

class SgtpPeerLeft extends SgtpEvent {
  final String peerUUID;
  SgtpPeerLeft({required this.peerUUID});
}

class SgtpError extends SgtpEvent {
  final String error;
  SgtpError({required this.error});
}

class SgtpDisconnected extends SgtpEvent {}

/// A participant shared their chat metadata (name/avatar).
class SgtpChatMetadataReceived extends SgtpEvent {
  final String chatName;
  final Uint8List? avatarBytes;
  final String senderUUID;
  SgtpChatMetadataReceived({
    required this.chatName,
    this.avatarBytes,
    required this.senderUUID,
  });
}

/// A peer sent a read receipt for a specific message.
class SgtpMessageReadReceived extends SgtpEvent {
  final String readMessageId;
  final String readerUUID;
  final String? readerPublicKeyHex;
  SgtpMessageReadReceived({
    required this.readMessageId,
    required this.readerUUID,
    this.readerPublicKeyHex,
  });
}

/// Upload progress for our own outgoing media.
class SgtpMediaProgress extends SgtpEvent {
  final String echoId;
  final String messageId;
  final double progress; // 0.0–1.0
  SgtpMediaProgress({
    required this.echoId,
    required this.messageId,
    required this.progress,
  });
}

/// A peer added or removed an emoji reaction on a message.
class SgtpReactionReceived extends SgtpEvent {
  final String messageId;
  final String emoji;
  final String senderUUID;
  final bool add;
  SgtpReactionReceived({
    required this.messageId,
    required this.emoji,
    required this.senderUUID,
    required this.add,
  });
}

class PersistedHistoryBatchResult {
  final int loaded;
  final int total;

  const PersistedHistoryBatchResult({
    required this.loaded,
    required this.total,
  });
}
