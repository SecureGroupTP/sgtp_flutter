import 'dart:typed_data';
import '../constants.dart';

/// A parsed SGTP frame with all header fields extracted.
class ParsedFrame {
  final Uint8List roomUUID;
  final Uint8List receiverUUID;
  final Uint8List senderUUID;
  final int version;
  final int packetType;
  final int payloadLength;
  final int timestamp;
  final Uint8List payload;
  final Uint8List signature;
  final Uint8List raw;

  const ParsedFrame({
    required this.roomUUID,
    required this.receiverUUID,
    required this.senderUUID,
    required this.version,
    required this.packetType,
    required this.payloadLength,
    required this.timestamp,
    required this.payload,
    required this.signature,
    required this.raw,
  });

  // ---- PING/PONG accessors (payload_length = 76) ----

  /// For PING/PONG: bytes [0:32] of payload = X25519 ephemeral public key
  Uint8List get x25519PubKey {
    return payload.sublist(0, 32);
  }

  /// For PING/PONG: bytes [32:64] of payload = Ed25519 long-term public key
  Uint8List get ed25519PubKey {
    return payload.sublist(32, 64);
  }

  // ---- INFO response accessors ----

  /// For INFO response: bytes [0:8] of payload as uint64 = peer count
  int get infoCount {
    final bd = ByteData.view(payload.buffer, payload.offsetInBytes, 8);
    return bd.getUint64(0, Endian.big);
  }

  /// For INFO response: parse peer UUIDs from payload[8:]
  List<Uint8List> get infoUUIDs {
    final count = infoCount;
    final result = <Uint8List>[];
    int off = 8;
    for (var i = 0; i < count; i++) {
      if (off + 16 > payload.length) break;
      result.add(Uint8List.fromList(payload.sublist(off, off + 16)));
      off += 16;
    }
    return result;
  }

  // ---- CHAT_REQUEST accessors ----

  /// For CHAT_REQUEST: count of known peers
  int get chatRequestCount {
    final bd = ByteData.view(payload.buffer, payload.offsetInBytes, 8);
    return bd.getUint64(0, Endian.big);
  }

  /// For CHAT_REQUEST: list of known peer UUIDs
  List<Uint8List> get chatRequestUUIDs {
    final count = chatRequestCount;
    final result = <Uint8List>[];
    int off = 8;
    for (var i = 0; i < count; i++) {
      if (off + 16 > payload.length) break;
      result.add(Uint8List.fromList(payload.sublist(off, off + 16)));
      off += 16;
    }
    return result;
  }

  // ---- CHAT_KEY accessors ----

  /// For CHAT_KEY: bytes [0:8] of payload = epoch (uint64)
  int get epoch {
    final bd = ByteData.view(payload.buffer, payload.offsetInBytes, 8);
    return bd.getUint64(0, Endian.big);
  }

  /// For CHAT_KEY: bytes [8:56] of payload = encrypted chat key (48 bytes)
  Uint8List get encryptedChatKey {
    return Uint8List.fromList(payload.sublist(8, 56));
  }

  // ---- MESSAGE accessors ----

  /// For MESSAGE: bytes [0:16] of payload = message UUID
  Uint8List get messageUUID {
    return Uint8List.fromList(payload.sublist(0, 16));
  }

  /// For MESSAGE: bytes [16:24] of payload = nonce (uint64)
  int get messageNonce {
    final bd = ByteData.view(payload.buffer, payload.offsetInBytes + 16, 8);
    return bd.getUint64(0, Endian.big);
  }

  /// For MESSAGE: bytes [24:] of payload = ciphertext (including 16B tag)
  Uint8List get messageCiphertext {
    return Uint8List.fromList(payload.sublist(24));
  }

  // ---- FIN accessors ----

  /// For FIN: bytes [0:8] of payload = nonce (uint64)
  int get finNonce {
    final bd = ByteData.view(payload.buffer, payload.offsetInBytes, 8);
    return bd.getUint64(0, Endian.big);
  }

  /// For FIN: bytes [8:24] of payload = Poly1305 tag (16 bytes)
  Uint8List get finTag {
    return Uint8List.fromList(payload.sublist(8, 24));
  }
}

/// Parse a complete frame from [raw] bytes.
/// Returns null if the bytes are too short or malformed.
ParsedFrame? tryParseFrame(Uint8List raw) {
  // Minimum frame: header (64) + signature (64) = 128 bytes
  if (raw.length < SgtpConstants.headerSize + SgtpConstants.signatureSize) {
    return null;
  }

  final bd = ByteData.view(raw.buffer, raw.offsetInBytes);

  final roomUUID = Uint8List.fromList(raw.sublist(0, 16));
  final receiverUUID = Uint8List.fromList(raw.sublist(16, 32));
  final senderUUID = Uint8List.fromList(raw.sublist(32, 48));
  final version = bd.getUint16(48, Endian.big);
  final packetType = bd.getUint16(50, Endian.big);
  final payloadLength = bd.getUint32(52, Endian.big);
  final timestamp = bd.getUint64(56, Endian.big);

  final totalExpected =
      SgtpConstants.headerSize + payloadLength + SgtpConstants.signatureSize;

  if (raw.length < totalExpected) {
    return null;
  }

  if (payloadLength > SgtpConstants.maxPayloadSize) {
    return null;
  }

  final payload = Uint8List.fromList(
      raw.sublist(SgtpConstants.headerSize, SgtpConstants.headerSize + payloadLength));
  final signature = Uint8List.fromList(raw.sublist(totalExpected - 64, totalExpected));
  final frameRaw = Uint8List.fromList(raw.sublist(0, totalExpected));

  return ParsedFrame(
    roomUUID: roomUUID,
    receiverUUID: receiverUUID,
    senderUUID: senderUUID,
    version: version,
    packetType: packetType,
    payloadLength: payloadLength,
    timestamp: timestamp,
    payload: payload,
    signature: signature,
    raw: frameRaw,
  );
}

/// Tries to extract one complete frame from the buffer.
/// Returns (frame, bytesConsumed) or null if not enough data.
({ParsedFrame frame, int bytesConsumed})? tryExtractFrame(List<int> buffer) {
  if (buffer.length < SgtpConstants.headerSize + SgtpConstants.signatureSize) {
    return null;
  }

  final bd = ByteData.view(Uint8List.fromList(
          buffer.sublist(0, SgtpConstants.headerSize))
      .buffer);
  final payloadLength = bd.getUint32(52, Endian.big);

  if (payloadLength > SgtpConstants.maxPayloadSize) {
    return null;
  }

  final totalExpected =
      SgtpConstants.headerSize + payloadLength + SgtpConstants.signatureSize;

  if (buffer.length < totalExpected) {
    return null;
  }

  final rawBytes = Uint8List.fromList(buffer.sublist(0, totalExpected));
  final frame = tryParseFrame(rawBytes);
  if (frame == null) return null;

  return (frame: frame, bytesConsumed: totalExpected);
}
