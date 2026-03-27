import 'dart:typed_data';

import 'package:equatable/equatable.dart';

enum MessageType {
  text,
  image,
  gif,
  video,
  voice,
}

/// Represents a chat message received or sent in the SGTP session.
class ChatMessage extends Equatable {
  /// Hex-encoded message UUID (16 bytes)
  final String id;

  /// Hex-encoded sender UUID (16 bytes)
  final String senderUUID;

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

  const ChatMessage({
    required this.id,
    required this.senderUUID,
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
  });

  @override
  List<Object?> get props => [
        id,
        senderUUID,
        content,
        imageBytes,
        videoBytes,
        audioBytes,
        mediaMime,
        mediaName,
        type,
        receivedAt,
        isFromHistory,
        isFromMe,
      ];
}
