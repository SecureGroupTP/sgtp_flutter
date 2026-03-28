// Добавить эти классы событий в lib/data/sgtp_client.dart

/// Received a CHAT_REQUEST with chat metadata
class SgtpChatRequestReceived extends SgtpEvent {
  /// UUID of the peer who sent the request
  final String senderUUID;

  /// Chat name from the request
  final String chatName;

  /// Chat avatar bytes (may be null)
  final Uint8List? avatarBytes;

  /// List of peer UUIDs included in the request
  final List<String> peerUUIDs;

  SgtpChatRequestReceived({
    required this.senderUUID,
    required this.chatName,
    this.avatarBytes,
    required this.peerUUIDs,
  });
}

/// Chat metadata received from other participant
class SgtpChatMetadataReceived extends SgtpEvent {
  final String chatName;
  final Uint8List? avatarBytes;

  SgtpChatMetadataReceived({
    required this.chatName,
    this.avatarBytes,
  });
}

/// Chat metadata has been updated locally
class SgtpChatMetadataUpdated extends SgtpEvent {
  final String chatName;
  final Uint8List? avatarBytes;

  SgtpChatMetadataUpdated({
    required this.chatName,
    this.avatarBytes,
  });
}
