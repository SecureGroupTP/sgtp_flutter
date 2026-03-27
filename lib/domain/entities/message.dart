import 'dart:typed_data';

import 'package:equatable/equatable.dart';

enum MessageType { text, image }

/// Represents a chat message received or sent in the SGTP session.
class ChatMessage extends Equatable {
  /// Hex-encoded message UUID (16 bytes)
  final String id;

  /// Hex-encoded sender UUID (16 bytes)
  final String senderUUID;

  /// Decrypted text content (empty for image messages)
  final String content;

  /// Raw image bytes (non-null for image messages)
  final Uint8List? imageBytes;

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
    this.type = MessageType.text,
    required this.receivedAt,
    required this.isFromHistory,
    required this.isFromMe,
  });

  @override
  List<Object?> get props =>
      [id, senderUUID, content, imageBytes, type, receivedAt, isFromHistory, isFromMe];
}
