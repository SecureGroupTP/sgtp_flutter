import 'dart:typed_data';

import 'package:sgtp_flutter/core/network/events/network_event.dart';
import 'package:sgtp_flutter/features/messaging/domain/entities/message.dart';

sealed class SgtpEvent extends NetworkEvent {
  const SgtpEvent();
}

class SgtpConnecting extends SgtpEvent {
  const SgtpConnecting();

  @override
  String get type => 'sgtp.connecting';
}

class SgtpHandshaking extends SgtpEvent {
  const SgtpHandshaking();

  @override
  String get type => 'sgtp.handshaking';
}

class SgtpReady extends SgtpEvent {
  final bool isMaster;
  final String roomUUIDHex;
  SgtpReady({required this.isMaster, required this.roomUUIDHex});

  @override
  String get type => 'sgtp.ready';
}

class SgtpMessageReceived extends SgtpEvent {
  final ChatMessage message;
  SgtpMessageReceived({required this.message});

  @override
  String get type => 'sgtp.message_received';
}

class SgtpPeerJoined extends SgtpEvent {
  final String peerUUID;
  final String ed25519PubHex;
  SgtpPeerJoined({required this.peerUUID, required this.ed25519PubHex});

  @override
  String get type => 'sgtp.peer_joined';
}

class SgtpPeerLeft extends SgtpEvent {
  final String peerUUID;
  SgtpPeerLeft({required this.peerUUID});

  @override
  String get type => 'sgtp.peer_left';
}

class SgtpError extends SgtpEvent {
  final String error;
  SgtpError({required this.error});

  @override
  String get type => 'sgtp.error';
}

class SgtpDisconnected extends SgtpEvent {
  const SgtpDisconnected();

  @override
  String get type => 'sgtp.disconnected';
}

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

  @override
  String get type => 'sgtp.chat_metadata_received';
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

  @override
  String get type => 'sgtp.message_read_received';
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

  @override
  String get type => 'sgtp.media_progress';
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

  @override
  String get type => 'sgtp.reaction_received';
}

class PersistedHistoryBatchResult {
  final int loaded;
  final int total;

  const PersistedHistoryBatchResult({
    required this.loaded,
    required this.total,
  });
}
