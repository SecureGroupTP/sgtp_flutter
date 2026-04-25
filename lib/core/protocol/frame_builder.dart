import 'dart:convert';
import 'dart:typed_data';
import 'package:sgtp_flutter/core/constants.dart';
import 'package:sgtp_flutter/core/uint64_utils.dart';
import 'package:sgtp_flutter/core/protocol/packet_types.dart';

void _writeHeader(
  ByteData bd,
  Uint8List roomUUID,
  Uint8List receiverUUID,
  Uint8List senderUUID,
  int packetType,
  int payloadLength,
  {int version = SgtpConstants.version,}
) {
  for (var i = 0; i < 16; i++) bd.setUint8(i, roomUUID[i]);
  for (var i = 0; i < 16; i++) bd.setUint8(16 + i, receiverUUID[i]);
  for (var i = 0; i < 16; i++) bd.setUint8(32 + i, senderUUID[i]);
  bd.setUint16(48, version, Endian.big);
  bd.setUint16(50, packetType, Endian.big);
  bd.setUint32(52, payloadLength, Endian.big);
  bdSetUint64(bd, 56, DateTime.now().millisecondsSinceEpoch, Endian.big);
}

Uint8List _allocFrame(int payloadLength) =>
    Uint8List(SgtpConstants.headerSize + payloadLength + SgtpConstants.signatureSize);

Uint8List buildIntentFrame(Uint8List roomUUID, Uint8List senderUUID) {
  const payloadLength = 0;
  final frame = _allocFrame(payloadLength);
  final bd = ByteData.view(frame.buffer);
  _writeHeader(bd, roomUUID, SgtpConstants.broadcastUUID, senderUUID,
      PacketType.intent, payloadLength);
  return frame;
}

Uint8List buildPingFrame(
  Uint8List roomUUID, Uint8List receiverUUID, Uint8List senderUUID,
  Uint8List x25519PubKey, Uint8List ed25519PubKey,
  {int version = SgtpConstants.version,}
) {
  const payloadLength = SgtpConstants.pingPayloadLength;
  final frame = _allocFrame(payloadLength);
  final bd = ByteData.view(frame.buffer);
  _writeHeader(bd, roomUUID, receiverUUID, senderUUID, PacketType.ping, payloadLength,
      version: version);
  int off = SgtpConstants.headerSize;
  frame.setRange(off, off + 32, x25519PubKey); off += 32;
  frame.setRange(off, off + 32, ed25519PubKey); off += 32;
  frame.setRange(off, off + 12, ascii.encode(SgtpConstants.clientHello));
  return frame;
}

Uint8List buildPongFrame(
  Uint8List roomUUID, Uint8List receiverUUID, Uint8List senderUUID,
  Uint8List x25519PubKey, Uint8List ed25519PubKey,
  {int version = SgtpConstants.version,}
) {
  const payloadLength = SgtpConstants.pingPayloadLength;
  final frame = _allocFrame(payloadLength);
  final bd = ByteData.view(frame.buffer);
  _writeHeader(bd, roomUUID, receiverUUID, senderUUID, PacketType.pong, payloadLength,
      version: version);
  int off = SgtpConstants.headerSize;
  frame.setRange(off, off + 32, x25519PubKey); off += 32;
  frame.setRange(off, off + 32, ed25519PubKey); off += 32;
  frame.setRange(off, off + 12, ascii.encode(SgtpConstants.clientHello));
  return frame;
}

Uint8List buildInfoRequest(Uint8List roomUUID, Uint8List receiverUUID, Uint8List senderUUID) {
  final frame = _allocFrame(0);
  final bd = ByteData.view(frame.buffer);
  _writeHeader(bd, roomUUID, receiverUUID, senderUUID, PacketType.info, 0);
  return frame;
}

Uint8List buildInfoResponse(
  Uint8List roomUUID, Uint8List receiverUUID, Uint8List senderUUID,
  List<Uint8List> peerUUIDs,
) {
  final payloadLength = 8 + peerUUIDs.length * 16;
  final frame = _allocFrame(payloadLength);
  final bd = ByteData.view(frame.buffer);
  _writeHeader(bd, roomUUID, receiverUUID, senderUUID, PacketType.info, payloadLength);
  int off = SgtpConstants.headerSize;
  bdSetUint64(bd, off, peerUUIDs.length, Endian.big); off += 8;
  for (final uuid in peerUUIDs) {
    frame.setRange(off, off + 16, uuid); off += 16;
  }
  return frame;
}

/// CHAT_REQUEST — peer_count(8B) + peer_uuids(16B each)
///              + chat_name_length(4B) + chat_name(UTF-8)
///              + avatar_length(4B) + avatar_bytes (max 4KB)
Uint8List buildChatRequest(
  Uint8List roomUUID, Uint8List masterUUID, Uint8List senderUUID,
  List<Uint8List> peerUUIDs, {
  String chatName = 'Chat',
  Uint8List? chatAvatarBytes,
}) {
  final avatar = chatAvatarBytes;

  final nameUtf8 = utf8.encode(chatName);
  if (nameUtf8.length > 255) throw ArgumentError('Chat name must be ≤ 255 UTF-8 bytes');

  final payloadLength = 8 + peerUUIDs.length * 16 + 4 + nameUtf8.length + 4 + (avatar?.length ?? 0);
  final frame = _allocFrame(payloadLength);
  final bd = ByteData.view(frame.buffer);
  _writeHeader(bd, roomUUID, masterUUID, senderUUID, PacketType.chatRequest, payloadLength);

  int off = SgtpConstants.headerSize;
  bdSetUint64(bd, off, peerUUIDs.length, Endian.big); off += 8;
  for (final uuid in peerUUIDs) {
    frame.setRange(off, off + 16, uuid); off += 16;
  }
  bd.setUint32(off, nameUtf8.length, Endian.big); off += 4;
  frame.setRange(off, off + nameUtf8.length, nameUtf8); off += nameUtf8.length;
  bd.setUint32(off, avatar?.length ?? 0, Endian.big); off += 4;
  if (avatar != null && avatar.isNotEmpty) {
    frame.setRange(off, off + avatar.length, avatar);
  }
  return frame;
}

Uint8List buildChatKey(
  Uint8List roomUUID, Uint8List receiverUUID, Uint8List senderUUID,
  int epoch, int nonce, Uint8List encryptedKey48, {int version = SgtpConstants.version,}
) {
  final payloadLength = version >= 0x0002
      ? SgtpConstants.chatKeyPayloadLengthV2
      : SgtpConstants.chatKeyPayloadLengthV1;
  final frame = _allocFrame(payloadLength);
  final bd = ByteData.view(frame.buffer);
  _writeHeader(
    bd,
    roomUUID,
    receiverUUID,
    senderUUID,
    PacketType.chatKey,
    payloadLength,
    version: version,
  );
  int off = SgtpConstants.headerSize;
  bdSetUint64(bd, off, epoch, Endian.big); off += 8;
  if (version >= 0x0002) {
    bdSetUint64(bd, off, nonce, Endian.big);
    off += 8;
  }
  frame.setRange(off, off + 48, encryptedKey48);
  return frame;
}

Uint8List buildChatKeyAck(
  Uint8List roomUUID,
  Uint8List masterUUID,
  Uint8List senderUUID,
  int epoch, {
  int version = SgtpConstants.version,
}) {
  final payloadLength = version >= 0x0002 ? 8 : 0;
  final frame = _allocFrame(payloadLength);
  final bd = ByteData.view(frame.buffer);
  _writeHeader(
    bd,
    roomUUID,
    masterUUID,
    senderUUID,
    PacketType.chatKeyAck,
    payloadLength,
    version: version,
  );
  if (payloadLength == 8) {
    bdSetUint64(bd, SgtpConstants.headerSize, epoch, Endian.big);
  }
  return frame;
}

Uint8List buildStatus(
  Uint8List roomUUID,
  Uint8List receiverUUID,
  Uint8List senderUUID,
  Uint8List payloadCipher, {
  int version = SgtpConstants.version,
}) {
  final frame = _allocFrame(payloadCipher.length);
  final bd = ByteData.view(frame.buffer);
  _writeHeader(
    bd,
    roomUUID,
    receiverUUID,
    senderUUID,
    PacketType.status,
    payloadCipher.length,
    version: version,
  );
  frame.setRange(
    SgtpConstants.headerSize,
    SgtpConstants.headerSize + payloadCipher.length,
    payloadCipher,
  );
  return frame;
}

Uint8List buildMessage(
  Uint8List roomUUID, Uint8List senderUUID, Uint8List messageUUID,
  int nonce, Uint8List ciphertext,
) {
  final payloadLength = 16 + 8 + ciphertext.length;
  final frame = _allocFrame(payloadLength);
  final bd = ByteData.view(frame.buffer);
  _writeHeader(bd, roomUUID, SgtpConstants.broadcastUUID, senderUUID,
      PacketType.message, payloadLength);
  int off = SgtpConstants.headerSize;
  frame.setRange(off, off + 16, messageUUID); off += 16;
  bdSetUint64(bd, off, nonce, Endian.big); off += 8;
  frame.setRange(off, off + ciphertext.length, ciphertext);
  return frame;
}

Uint8List buildMessageFailedAck(
  Uint8List roomUUID, Uint8List masterUUID, Uint8List senderUUID,
) {
  final frame = _allocFrame(0);
  final bd = ByteData.view(frame.buffer);
  _writeHeader(bd, roomUUID, masterUUID, senderUUID, PacketType.messageFailedAck, 0);
  return frame;
}

Uint8List buildFin(Uint8List roomUUID, Uint8List senderUUID, int nonce, Uint8List tag16) {
  const payloadLength = SgtpConstants.finPayloadLength;
  final frame = _allocFrame(payloadLength);
  final bd = ByteData.view(frame.buffer);
  _writeHeader(bd, roomUUID, SgtpConstants.broadcastUUID, senderUUID,
      PacketType.fin, payloadLength);
  int off = SgtpConstants.headerSize;
  bdSetUint64(bd, off, nonce, Endian.big); off += 8;
  frame.setRange(off, off + 16, tag16);
  return frame;
}

Uint8List buildHsir(Uint8List roomUUID, Uint8List senderUUID) {
  final frame = _allocFrame(0);
  final bd = ByteData.view(frame.buffer);
  _writeHeader(bd, roomUUID, SgtpConstants.broadcastUUID, senderUUID, PacketType.hsir, 0);
  return frame;
}

Uint8List buildHsi(
  Uint8List roomUUID, Uint8List receiverUUID, Uint8List senderUUID, int messageCount,
) {
  const payloadLength = 8;
  final frame = _allocFrame(payloadLength);
  final bd = ByteData.view(frame.buffer);
  _writeHeader(bd, roomUUID, receiverUUID, senderUUID, PacketType.hsi, payloadLength);
  bdSetUint64(bd, SgtpConstants.headerSize, messageCount, Endian.big);
  return frame;
}

Uint8List buildHsr(
  Uint8List roomUUID, Uint8List receiverUUID, Uint8List senderUUID, int offset, int limit,
) {
  const payloadLength = 16;
  final frame = _allocFrame(payloadLength);
  final bd = ByteData.view(frame.buffer);
  _writeHeader(bd, roomUUID, receiverUUID, senderUUID, PacketType.hsr, payloadLength);
  bdSetUint64(bd, SgtpConstants.headerSize,     offset, Endian.big);
  bdSetUint64(bd, SgtpConstants.headerSize + 8, limit, Endian.big);
  return frame;
}

Uint8List buildHsra(
  Uint8List roomUUID, Uint8List receiverUUID, Uint8List senderUUID,
  int batchNumber, List<Uint8List> messages,
) {
  final count = messages.length;
  final blobSize = messages.fold<int>(0, (s, m) => s + m.length);
  final payloadLength = 8 + 8 + count * 8 + blobSize;
  final frame = _allocFrame(payloadLength);
  final bd = ByteData.view(frame.buffer);
  _writeHeader(bd, roomUUID, receiverUUID, senderUUID, PacketType.hsra, payloadLength);
  int off = SgtpConstants.headerSize;
  bdSetUint64(bd, off, batchNumber, Endian.big); off += 8;
  bdSetUint64(bd, off, count, Endian.big); off += 8;
  var blobCursor = 0;
  for (final m in messages) { bdSetUint64(bd, off, blobCursor, Endian.big); off += 8; blobCursor += m.length; }
  for (final m in messages) { frame.setRange(off, off + m.length, m); off += m.length; }
  return frame;
}

Uint8List buildHsraEos(
  Uint8List roomUUID, Uint8List receiverUUID, Uint8List senderUUID, int totalSent,
) {
  const payloadLength = 16;
  final frame = _allocFrame(payloadLength);
  final bd = ByteData.view(frame.buffer);
  _writeHeader(bd, roomUUID, receiverUUID, senderUUID, PacketType.hsra, payloadLength);
  bdSetUint64(bd, SgtpConstants.headerSize,     totalSent, Endian.big);
  bdSetUint64(bd, SgtpConstants.headerSize + 8, 0, Endian.big);
  return frame;
}
