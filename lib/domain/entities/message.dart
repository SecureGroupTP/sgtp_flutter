import 'dart:typed_data';

import 'package:equatable/equatable.dart';

enum MessageType {
  text,
  image,
  gif,
  video,
  voice,
  videoNote,   // Circular video message (кружок)
  system,
  messageRead,
  reaction,
  viewed,
}

/// Represents a chat message received or sent in the SGTP session.
class ChatMessage extends Equatable {
  /// Hex-encoded message UUID (16 bytes)
  final String id;

  /// Hex-encoded sender UUID (16 bytes)
  final String senderUUID;

  /// Ed25519 public key hex of the sender (32 bytes = 64 hex chars).
  final String? senderPublicKeyHex;

  /// Decrypted text content (empty for media messages)
  final String content;

  /// Raw image/gif bytes (non-null for image/gif messages)
  final Uint8List? imageBytes;

  /// Raw video bytes (non-null for video messages)
  final Uint8List? videoBytes;

  /// Raw audio bytes (non-null for voice messages, opus/m4a/aac)
  final Uint8List? audioBytes;

  /// MIME type for media (e.g. 'image/jpeg', 'video/mp4', 'audio/m4a')
  final String? mediaMime;

  /// File name for media
  final String? mediaName;

  final MessageType type;

  /// When the message was received/created
  final DateTime receivedAt;

  /// Whether this message was received from history (replayed)
  final bool isFromHistory;

  /// Whether this message was sent by the local user
  final bool isFromMe;

  /// Sender's avatar bytes (if they sent one along with the message).
  final Uint8List? senderAvatarBytes;

  /// For messageRead type: the message ID that was read.
  final String? readMessageId;

  /// Set of peer UUIDs who have read this message (local tracking only).
  final Set<String> readBy;

  // ── Reply support ──────────────────────────────────────────────────────────

  /// ID of the message being replied to (null if not a reply).
  final String? replyToId;

  /// Short preview text of the replied-to message.
  final String? replyToContent;

  /// Display name of the sender of the replied-to message.
  final String? replyToSender;

  // ── Reactions ──────────────────────────────────────────────────────────────

  /// emoji → set of senderUUIDs who reacted with that emoji.
  final Map<String, Set<String>> reactions;

  /// True while this message is still being encrypted+sent.
  final bool isSending;

  /// Upload progress 0.0–1.0, only meaningful when isSending == true.
  final double sendProgress;

  const ChatMessage({
    required this.id,
    required this.senderUUID,
    this.senderPublicKeyHex,
    required this.content,
    this.imageBytes,
    this.videoBytes,
    this.audioBytes,
    this.mediaMime,
    this.mediaName,
    this.type = MessageType.text,
    required this.receivedAt,
    required this.isFromHistory,
    required this.isFromMe,
    this.senderAvatarBytes,
    this.readMessageId,
    this.readBy = const {},
    this.replyToId,
    this.replyToContent,
    this.replyToSender,
    this.reactions = const {},
    this.isSending = false,
    this.sendProgress = 0.0,
  });

  ChatMessage copyWith({
    String? id,
    String? senderUUID,
    String? senderPublicKeyHex,
    String? content,
    Uint8List? imageBytes,
    Uint8List? videoBytes,
    Uint8List? audioBytes,
    String? mediaMime,
    String? mediaName,
    MessageType? type,
    DateTime? receivedAt,
    bool? isFromHistory,
    bool? isFromMe,
    Uint8List? senderAvatarBytes,
    String? readMessageId,
    Set<String>? readBy,
    String? replyToId,
    String? replyToContent,
    String? replyToSender,
    Map<String, Set<String>>? reactions,
    bool? isSending,
    double? sendProgress,
  }) {
    return ChatMessage(
      id:                   id ?? this.id,
      senderUUID:           senderUUID ?? this.senderUUID,
      senderPublicKeyHex:   senderPublicKeyHex ?? this.senderPublicKeyHex,
      content:              content ?? this.content,
      imageBytes:           imageBytes ?? this.imageBytes,
      videoBytes:           videoBytes ?? this.videoBytes,
      audioBytes:           audioBytes ?? this.audioBytes,
      mediaMime:            mediaMime ?? this.mediaMime,
      mediaName:            mediaName ?? this.mediaName,
      type:                 type ?? this.type,
      receivedAt:           receivedAt ?? this.receivedAt,
      isFromHistory:        isFromHistory ?? this.isFromHistory,
      isFromMe:             isFromMe ?? this.isFromMe,
      senderAvatarBytes:    senderAvatarBytes ?? this.senderAvatarBytes,
      readMessageId:        readMessageId ?? this.readMessageId,
      readBy:               readBy ?? this.readBy,
      replyToId:            replyToId ?? this.replyToId,
      replyToContent:       replyToContent ?? this.replyToContent,
      replyToSender:        replyToSender ?? this.replyToSender,
      reactions:            reactions ?? this.reactions,
      isSending:            isSending ?? this.isSending,
      sendProgress:         sendProgress ?? this.sendProgress,
    );
  }

  @override
  List<Object?> get props => [
        id, senderUUID, senderPublicKeyHex, content,
        imageBytes, videoBytes, audioBytes, mediaMime, mediaName,
        type, receivedAt, isFromHistory, isFromMe, senderAvatarBytes,
        readMessageId, readBy, replyToId, replyToContent, replyToSender,
        reactions, isSending, sendProgress,
      ];
}

