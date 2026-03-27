import 'dart:convert';
import 'dart:typed_data';
import '../constants.dart';
import 'packet_types.dart';

/// Builds SGTP frames. The last 64 bytes are zeroed (signature placeholder).
/// After calling these functions, sign the frame with signFrame() from ed25519_utils.dart.

/// Write a 64-byte header into [buffer] at offset 0.
void _writeHeader(
  ByteData bd,
  Uint8List roomUUID,
  Uint8List receiverUUID,
  Uint8List senderUUID,
  int packetType,
  int payloadLength,
) {
  // [0:16] room_uuid
  for (var i = 0; i < 16; i++) {
    bd.setUint8(i, roomUUID[i]);
  }
  // [16:32] receiver_uuid
  for (var i = 0; i < 16; i++) {
    bd.setUint8(16 + i, receiverUUID[i]);
  }
  // [32:48] sender_uuid
  for (var i = 0; i < 16; i++) {
    bd.setUint8(32 + i, senderUUID[i]);
  }
  // [48:50] version
  bd.setUint16(48, SgtpConstants.version, Endian.big);
  // [50:52] packet_type
  bd.setUint16(50, packetType, Endian.big);
  // [52:56] payload_length
  bd.setUint32(52, payloadLength, Endian.big);
  // [56:64] timestamp (uint64, Unix ms)
  final ts = DateTime.now().millisecondsSinceEpoch;
  bd.setUint64(56, ts, Endian.big);
}

/// Allocate a frame buffer: header (64) + payload (payloadLength) + signature (64)
Uint8List _allocFrame(int payloadLength) {
  return Uint8List(
      SgtpConstants.headerSize + payloadLength + SgtpConstants.signatureSize);
}

/// Build an intent frame (announcement). No payload.
Uint8List buildIntentFrame(Uint8List roomUUID, Uint8List senderUUID) {
  const payloadLength = 0;
  final frame = _allocFrame(payloadLength);
  final bd = ByteData.view(frame.buffer);
  _writeHeader(bd, roomUUID, SgtpConstants.broadcastUUID, senderUUID,
      PacketType.intent, payloadLength);
  return frame;
}

/// Build a PING frame.
/// Payload (76 bytes):
///   [0:32]   x25519_pub_key (32B ephemeral)
///   [32:64]  ed25519_pub_key (32B long-term)
///   [64:76]  "Client Hello" (12B)
Uint8List buildPingFrame(
  Uint8List roomUUID,
  Uint8List receiverUUID,
  Uint8List senderUUID,
  Uint8List x25519PubKey,
  Uint8List ed25519PubKey,
) {
  const payloadLength = SgtpConstants.pingPayloadLength; // 76
  final frame = _allocFrame(payloadLength);
  final bd = ByteData.view(frame.buffer);
  _writeHeader(bd, roomUUID, receiverUUID, senderUUID, PacketType.ping,
      payloadLength);

  int off = SgtpConstants.headerSize;
  // x25519 pub key (32 bytes)
  frame.setRange(off, off + 32, x25519PubKey);
  off += 32;
  // ed25519 pub key (32 bytes)
  frame.setRange(off, off + 32, ed25519PubKey);
  off += 32;
  // "Client Hello" (12 bytes)
  final helloBytes = ascii.encode(SgtpConstants.clientHello);
  frame.setRange(off, off + 12, helloBytes);

  return frame;
}

/// Build a PONG frame. Same structure as PING but with pong packet type.
Uint8List buildPongFrame(
  Uint8List roomUUID,
  Uint8List receiverUUID,
  Uint8List senderUUID,
  Uint8List x25519PubKey,
  Uint8List ed25519PubKey,
) {
  const payloadLength = SgtpConstants.pingPayloadLength; // 76
  final frame = _allocFrame(payloadLength);
  final bd = ByteData.view(frame.buffer);
  _writeHeader(bd, roomUUID, receiverUUID, senderUUID, PacketType.pong,
      payloadLength);

  int off = SgtpConstants.headerSize;
  frame.setRange(off, off + 32, x25519PubKey);
  off += 32;
  frame.setRange(off, off + 32, ed25519PubKey);
  off += 32;
  final helloBytes = ascii.encode(SgtpConstants.clientHello);
  frame.setRange(off, off + 12, helloBytes);

  return frame;
}

/// Build an INFO request frame. No payload.
Uint8List buildInfoRequest(
  Uint8List roomUUID,
  Uint8List receiverUUID,
  Uint8List senderUUID,
) {
  const payloadLength = 0;
  final frame = _allocFrame(payloadLength);
  final bd = ByteData.view(frame.buffer);
  _writeHeader(bd, roomUUID, receiverUUID, senderUUID, PacketType.info,
      payloadLength);
  return frame;
}

/// Build an INFO response frame.
/// Payload:
///   [0:8]           count (uint64)
///   [8:8+count*16]  uuids
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
  _writeHeader(bd, roomUUID, receiverUUID, senderUUID, PacketType.info,
      payloadLength);

  int off = SgtpConstants.headerSize;
  bd.setUint64(off, count, Endian.big);
  off += 8;
  for (final uuid in peerUUIDs) {
    frame.setRange(off, off + 16, uuid);
    off += 16;
  }

  return frame;
}

/// Build a CHAT_REQUEST frame.
/// Payload:
///   [0:8]           count (uint64)
///   [8:8+count*16]  known peer uuids
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
  _writeHeader(bd, roomUUID, masterUUID, senderUUID, PacketType.chatRequest,
      payloadLength);

  int off = SgtpConstants.headerSize;
  bd.setUint64(off, count, Endian.big);
  off += 8;
  for (final uuid in peerUUIDs) {
    frame.setRange(off, off + 16, uuid);
    off += 16;
  }

  return frame;
}

/// Build a CHAT_KEY frame.
/// Payload (56 bytes):
///   [0:8]   epoch (uint64, open text, used as nonce)
///   [8:56]  ciphertext (48B: 32B key + 16B poly1305 tag)
Uint8List buildChatKey(
  Uint8List roomUUID,
  Uint8List receiverUUID,
  Uint8List senderUUID,
  int epoch,
  Uint8List encryptedKey48,
) {
  const payloadLength = SgtpConstants.chatKeyPayloadLength; // 56
  final frame = _allocFrame(payloadLength);
  final bd = ByteData.view(frame.buffer);
  _writeHeader(bd, roomUUID, receiverUUID, senderUUID, PacketType.chatKey,
      payloadLength);

  int off = SgtpConstants.headerSize;
  bd.setUint64(off, epoch, Endian.big);
  off += 8;
  frame.setRange(off, off + 48, encryptedKey48);

  return frame;
}

/// Build a CHAT_KEY_ACK frame. No payload.
Uint8List buildChatKeyAck(
  Uint8List roomUUID,
  Uint8List masterUUID,
  Uint8List senderUUID,
) {
  const payloadLength = 0;
  final frame = _allocFrame(payloadLength);
  final bd = ByteData.view(frame.buffer);
  _writeHeader(bd, roomUUID, masterUUID, senderUUID, PacketType.chatKeyAck,
      payloadLength);
  return frame;
}

/// Build a MESSAGE frame.
/// Payload:
///   [0:16]    message_uuid (16B)
///   [16:24]   nonce (uint64)
///   [24:24+N] ciphertext (N bytes including 16B poly1305 tag)
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
  frame.setRange(off, off + 16, messageUUID);
  off += 16;
  bd.setUint64(off, nonce, Endian.big);
  off += 8;
  frame.setRange(off, off + ciphertext.length, ciphertext);

  return frame;
}

/// Build a FIN frame.
/// Payload (24 bytes):
///   [0:8]   nonce (uint64)
///   [8:24]  ciphertext (16B poly1305 tag of empty plaintext)
Uint8List buildFin(
  Uint8List roomUUID,
  Uint8List senderUUID,
  int nonce,
  Uint8List tag16,
) {
  const payloadLength = SgtpConstants.finPayloadLength; // 24
  final frame = _allocFrame(payloadLength);
  final bd = ByteData.view(frame.buffer);
  _writeHeader(bd, roomUUID, SgtpConstants.broadcastUUID, senderUUID,
      PacketType.fin, payloadLength);

  int off = SgtpConstants.headerSize;
  bd.setUint64(off, nonce, Endian.big);
  off += 8;
  frame.setRange(off, off + 16, tag16);

  return frame;
}
