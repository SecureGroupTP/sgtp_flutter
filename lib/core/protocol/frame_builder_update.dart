/// CHAT_REQUEST с метаданными чата
/// Payload structure:
/// - peer_count(8B)
/// - peer_uuids(16B each)
/// - chat_name_length(4B)
/// - chat_name(UTF-8 bytes)
/// - avatar_length(4B)
/// - avatar_bytes(binary, max 4KB)
Uint8List buildChatRequest(
  Uint8List roomUUID,
  Uint8List masterUUID,
  Uint8List senderUUID,
  List<Uint8List> peerUUIDs, {
  String chatName = 'Chat',
  Uint8List? chatAvatarBytes,
}) {
  // Limit avatar to 4KB
  final avatarBytes = (chatAvatarBytes != null && chatAvatarBytes.length > 4096)
      ? chatAvatarBytes.sublist(0, 4096)
      : chatAvatarBytes;

  final nameUtf8 = utf8.encode(chatName);
  if (nameUtf8.length > 255) {
    throw ArgumentError('Chat name must be <= 255 bytes in UTF-8');
  }

  // Calculate payload size
  final basePayload = 8 + (peerUUIDs.length * 16) + 4 + nameUtf8.length + 4;
  final avatarPayload = avatarBytes?.length ?? 0;
  final payloadLength = basePayload + avatarPayload;

  final frame = _allocFrame(payloadLength);
  final bd = ByteData.view(frame.buffer);

  _writeHeader(
    bd,
    roomUUID,
    masterUUID,
    senderUUID,
    PacketType.chatRequest,
    payloadLength,
  );

  int off = SgtpConstants.headerSize;

  // Write peer count
  bd.setUint64(off, peerUUIDs.length, Endian.big);
  off += 8;

  // Write peer UUIDs
  for (final uuid in peerUUIDs) {
    frame.setRange(off, off + 16, uuid);
    off += 16;
  }

  // Write chat name length and name
  bd.setUint32(off, nameUtf8.length, Endian.big);
  off += 4;
  frame.setRange(off, off + nameUtf8.length, nameUtf8);
  off += nameUtf8.length;

  // Write avatar length and bytes
  bd.setUint32(off, avatarBytes?.length ?? 0, Endian.big);
  off += 4;
  if (avatarBytes != null && avatarBytes.isNotEmpty) {
    frame.setRange(off, off + avatarBytes.length, avatarBytes);
  }

  return frame;
}
