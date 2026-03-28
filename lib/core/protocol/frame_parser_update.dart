/// Parsed CHAT_REQUEST with chat metadata
class ParsedChatRequest {
  final List<Uint8List> peerUUIDs;
  final String chatName;
  final Uint8List? avatarBytes;

  const ParsedChatRequest({
    required this.peerUUIDs,
    required this.chatName,
    this.avatarBytes,
  });
}

/// Parse CHAT_REQUEST frame payload
/// Returns (peerUUIDs, chatName, avatarBytes)
ParsedChatRequest parseChatRequest(Uint8List payload) {
  if (payload.length < 12) {
    throw FormatException('CHAT_REQUEST payload too short');
  }

  final bd = ByteData.view(payload.buffer, payload.offsetInBytes, payload.lengthInBytes);
  int off = 0;

  // Read peer count
  final peerCount = bd.getUint64(off, Endian.big);
  off += 8;

  if (payload.length < 8 + peerCount * 16 + 8) {
    throw FormatException('CHAT_REQUEST payload incomplete for peer list');
  }

  // Read peer UUIDs
  final peerUUIDs = <Uint8List>[];
  for (int i = 0; i < peerCount; i++) {
    final uuid = payload.sublist(off, off + 16);
    peerUUIDs.add(Uint8List.fromList(uuid));
    off += 16;
  }

  // Read chat name
  if (off + 4 > payload.length) {
    throw FormatException('CHAT_REQUEST: missing name length');
  }

  final nameLength = bd.getUint32(off, Endian.big);
  off += 4;

  if (off + nameLength > payload.length) {
    throw FormatException('CHAT_REQUEST: name length exceeds payload');
  }

  final nameBytes = payload.sublist(off, off + nameLength);
  final chatName = utf8.decode(nameBytes);
  off += nameLength;

  // Read avatar
  if (off + 4 > payload.length) {
    throw FormatException('CHAT_REQUEST: missing avatar length');
  }

  final avatarLength = bd.getUint32(off, Endian.big);
  off += 4;

  if (off + avatarLength > payload.length) {
    throw FormatException('CHAT_REQUEST: avatar length exceeds payload');
  }

  Uint8List? avatarBytes;
  if (avatarLength > 0) {
    avatarBytes = Uint8List.fromList(payload.sublist(off, off + avatarLength));
  }

  return ParsedChatRequest(
    peerUUIDs: peerUUIDs,
    chatName: chatName,
    avatarBytes: avatarBytes,
  );
}
