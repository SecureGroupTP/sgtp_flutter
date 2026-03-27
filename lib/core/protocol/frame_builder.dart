import 'dart:convert';
import 'dart:typed_data';
import '../constants.dart';
import 'packet_types.dart';

/// Builds SGTP frames. The last 64 bytes are zeroed (signature placeholder).
/// After calling these functions, sign the frame with signFrame() from ed25519_utils.dart.

void _writeHeader(
  ByteData bd,
  Uint8List roomUUID,
  Uint8List receiverUUID,
  Uint8List senderUUID,
  int packetType,
  int payloadLength,
) {
  for (var i = 0; i < 16; i++) bd.setUint8(i, roomUUID[i]);
  for (var i = 0; i < 16; i++) bd.setUint8(16 + i, receiverUUID[i]);
  for (var i = 0; i < 16; i++) bd.setUint8(32 + i, senderUUID[i]);
  bd.setUint16(48, SgtpConstants.version, Endian.big);
  bd.setUint16(50, packetType, Endian.big);
  bd.setUint32(52, payloadLength, Endian.big);
  bd.setUint64(56, DateTime.now().millisecondsSinceEpoch, Endian.big);
}

Uint8List _allocFrame(int payloadLength) =>
    Uint8List(SgtpConstants.headerSize + payloadLength + SgtpConstants.signatureSize);

/// Intent frame — header only, no payload.
Uint8List buildIntentFrame(Uint8List roomUUID, Uint8List senderUUID) {
  const payloadLength = 0;
  final frame = _allocFrame(payloadLength);
  final bd = ByteData.view(frame.buffer);
  _writeHeader(bd, roomUUID, SgtpConstants.broadcastUUID, senderUUID,
      PacketType.intent, payloadLength);
  return frame;
}

/// PING frame: 32B x25519 + 32B ed25519 + "Client Hello" (12B) = 76B payload
Uint8List buildPingFrame(
  Uint8List roomUUID,
  Uint8List receiverUUID,
  Uint8List senderUUID,
  Uint8List x25519PubKey,
  Uint8List ed25519PubKey,
) {
  const payloadLength = SgtpConstants.pingPayloadLength;
  final frame = _allocFrame(payloadLength);
  final bd = ByteData.view(frame.buffer);
  _writeHeader(bd, roomUUID, receiverUUID, senderUUID, PacketType.ping, payloadLength);

  int off = SgtpConstants.headerSize;
  frame.setRange(off, off + 32, x25519PubKey); off += 32;
  frame.setRange(off, off + 32, ed25519PubKey); off += 32;
  frame.setRange(off, off + 12, ascii.encode(SgtpConstants.clientHello));
  return frame;
}

/// PONG frame — same structure as PING.
Uint8List buildPongFrame(
  Uint8List roomUUID,
  Uint8List receiverUUID,
  Uint8List senderUUID,
  Uint8List x25519PubKey,
  Uint8List ed25519PubKey,
) {
  const payloadLength = SgtpConstants.pingPayloadLength;
  final frame = _allocFrame(payloadLength);
  final bd = ByteData.view(frame.buffer);
  _writeHeader(bd, roomUUID, receiverUUID, senderUUID, PacketType.pong, payloadLength);

  int off = SgtpConstants.headerSize;
  frame.setRange(off, off + 32, x25519PubKey); off += 32;
  frame.setRange(off, off + 32, ed25519PubKey); off += 32;
  frame.setRange(off, off + 12, ascii.encode(SgtpConstants.clientHello));
  return frame;
}

/// INFO request — no payload.
Uint8List buildInfoRequest(Uint8List roomUUID, Uint8List receiverUUID, Uint8List senderUUID) {
  const payloadLength = 0;
  final frame = _allocFrame(payloadLength);
  final bd = ByteData.view(frame.buffer);
  _writeHeader(bd, roomUUID, receiverUUID, senderUUID, PacketType.info, payloadLength);
  return frame;
}

/// INFO response — count(8B) + uuids.
Uint8List buildInfoResponse(
  Uint8List roomUUID,
  Uint8List receiverUUID,
  Uint8List senderUUID,
  List<Uint8List> peerUUIDs,
) {
  final count = peerUUIDs.length;
  final payloadLength = 8 + count * 16;
  final frame = _allocFrame(payloadLength);
  final bd = ByteData.view(frame.buffer);
  _writeHeader(bd, roomUUID, receiverUUID, senderUUID, PacketType.info, payloadLength);

  int off = SgtpConstants.headerSize;
  bd.setUint64(off, count, Endian.big); off += 8;
  for (final uuid in peerUUIDs) {
    frame.setRange(off, off + 16, uuid); off += 16;
  }
  return frame;
}

/// CHAT_REQUEST — count(8B) + uuids.
Uint8List buildChatRequest(
  Uint8List roomUUID,
  Uint8List masterUUID,
  Uint8List senderUUID,
  List<Uint8List> peerUUIDs,
) {
  final count = peerUUIDs.length;
  final payloadLength = 8 + count * 16;
  final frame = _allocFrame(payloadLength);
  final bd = ByteData.view(frame.buffer);
  _writeHeader(bd, roomUUID, masterUUID, senderUUID, PacketType.chatRequest, payloadLength);

  int off = SgtpConstants.headerSize;
  bd.setUint64(off, count, Endian.big); off += 8;
  for (final uuid in peerUUIDs) {
    frame.setRange(off, off + 16, uuid); off += 16;
  }
  return frame;
}

/// CHAT_KEY — epoch(8B) + ciphertext(48B).
Uint8List buildChatKey(
  Uint8List roomUUID,
  Uint8List receiverUUID,
  Uint8List senderUUID,
  int epoch,
  Uint8List encryptedKey48,
) {
  const payloadLength = SgtpConstants.chatKeyPayloadLength;
  final frame = _allocFrame(payloadLength);
  final bd = ByteData.view(frame.buffer);
  _writeHeader(bd, roomUUID, receiverUUID, senderUUID, PacketType.chatKey, payloadLength);

  int off = SgtpConstants.headerSize;
  bd.setUint64(off, epoch, Endian.big); off += 8;
  frame.setRange(off, off + 48, encryptedKey48);
  return frame;
}

/// CHAT_KEY_ACK — no payload.
Uint8List buildChatKeyAck(Uint8List roomUUID, Uint8List masterUUID, Uint8List senderUUID) {
  final frame = _allocFrame(0);
  final bd = ByteData.view(frame.buffer);
  _writeHeader(bd, roomUUID, masterUUID, senderUUID, PacketType.chatKeyAck, 0);
  return frame;
}

/// MESSAGE — messageUUID(16B) + nonce(8B) + ciphertext.
Uint8List buildMessage(
  Uint8List roomUUID,
  Uint8List senderUUID,
  Uint8List messageUUID,
  int nonce,
  Uint8List ciphertext,
) {
  final payloadLength = 16 + 8 + ciphertext.length;
  final frame = _allocFrame(payloadLength);
  final bd = ByteData.view(frame.buffer);
  _writeHeader(bd, roomUUID, SgtpConstants.broadcastUUID, senderUUID,
      PacketType.message, payloadLength);

  int off = SgtpConstants.headerSize;
  frame.setRange(off, off + 16, messageUUID); off += 16;
  bd.setUint64(off, nonce, Endian.big); off += 8;
  frame.setRange(off, off + ciphertext.length, ciphertext);
  return frame;
}

/// MESSAGE_FAILED_ACK — no payload.
Uint8List buildMessageFailedAck(
  Uint8List roomUUID,
  Uint8List masterUUID,
  Uint8List senderUUID,
) {
  final frame = _allocFrame(0);
  final bd = ByteData.view(frame.buffer);
  _writeHeader(bd, roomUUID, masterUUID, senderUUID, PacketType.messageFailedAck, 0);
  return frame;
}

/// FIN — nonce(8B) + poly1305-tag(16B).
Uint8List buildFin(
  Uint8List roomUUID,
  Uint8List senderUUID,
  int nonce,
  Uint8List tag16,
) {
  const payloadLength = SgtpConstants.finPayloadLength;
  final frame = _allocFrame(payloadLength);
  final bd = ByteData.view(frame.buffer);
  _writeHeader(bd, roomUUID, SgtpConstants.broadcastUUID, senderUUID,
      PacketType.fin, payloadLength);

  int off = SgtpConstants.headerSize;
  bd.setUint64(off, nonce, Endian.big); off += 8;
  frame.setRange(off, off + 16, tag16);
  return frame;
}

/// HSIR — History Info Request (broadcast, no payload).
Uint8List buildHsir(Uint8List roomUUID, Uint8List senderUUID) {
  final frame = _allocFrame(0);
  final bd = ByteData.view(frame.buffer);
  _writeHeader(bd, roomUUID, SgtpConstants.broadcastUUID, senderUUID, PacketType.hsir, 0);
  return frame;
}

/// HSR — History Request: offset(8B) + limit(8B).
Uint8List buildHsr(
  Uint8List roomUUID,
  Uint8List receiverUUID,
  Uint8List senderUUID,
  int offset,
  int limit,
) {
  const payloadLength = 16;
  final frame = _allocFrame(payloadLength);
  final bd = ByteData.view(frame.buffer);
  _writeHeader(bd, roomUUID, receiverUUID, senderUUID, PacketType.hsr, payloadLength);
  bd.setUint64(SgtpConstants.headerSize, offset, Endian.big);
  bd.setUint64(SgtpConstants.headerSize + 8, limit, Endian.big);
  return frame;
}
