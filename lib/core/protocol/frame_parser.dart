import 'dart:convert';
import 'dart:typed_data';
import '../constants.dart';
import '../uint64_utils.dart';

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

  // ---- PING/PONG accessors ----

  Uint8List get x25519PubKey => payload.sublist(0, 32);
  Uint8List get ed25519PubKey => payload.sublist(32, 64);

  // ---- INFO response accessors ----

  int get infoCount {
    final bd = ByteData.view(payload.buffer, payload.offsetInBytes, 8);
    return bdGetUint64(bd, 0, Endian.big);
  }

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

  int get chatRequestCount {
    final bd = ByteData.view(payload.buffer, payload.offsetInBytes, 8);
    return bdGetUint64(bd, 0, Endian.big);
  }

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

  int get epoch {
    final bd = ByteData.view(payload.buffer, payload.offsetInBytes, 8);
    return bdGetUint64(bd, 0, Endian.big);
  }

  /// Nonce used to encrypt/decrypt the CHAT_KEY payload.
  ///
  /// v1: equals [epoch].
  /// v2+: stored explicitly in payload[8:16].
  int get chatKeyEncryptionNonce {
    if (version >= 0x0002 && payload.length >= 16) {
      final bd = ByteData.view(payload.buffer, payload.offsetInBytes + 8, 8);
      return bdGetUint64(bd, 0, Endian.big);
    }
    return epoch;
  }

  Uint8List get encryptedChatKey {
    if (version >= 0x0002) {
      if (payload.length < 16 + 48) return Uint8List(0);
      return Uint8List.fromList(payload.sublist(16, 16 + 48));
    }
    if (payload.length < 8 + 48) return Uint8List(0);
    return Uint8List.fromList(payload.sublist(8, 8 + 48));
  }

  // ---- MESSAGE accessors ----

  Uint8List get messageUUID =>
      Uint8List.fromList(payload.sublist(0, 16));

  int get messageNonce {
    final bd = ByteData.view(payload.buffer, payload.offsetInBytes + 16, 8);
    return bdGetUint64(bd, 0, Endian.big);
  }

  Uint8List get messageCiphertext =>
      Uint8List.fromList(payload.sublist(24));

  // ---- FIN accessors ----

  int get finNonce {
    final bd = ByteData.view(payload.buffer, payload.offsetInBytes, 8);
    return bdGetUint64(bd, 0, Endian.big);
  }

  Uint8List get finTag =>
      Uint8List.fromList(payload.sublist(8, 24));

  // ---- HSI accessors ----

  /// For HSI: payload[0:8] = number of stored messages (uint64).
  int get hsiMessageCount {
    if (payload.length < 8) return 0;
    final bd = ByteData.view(payload.buffer, payload.offsetInBytes, 8);
    return bdGetUint64(bd, 0, Endian.big);
  }

  // ---- HSRA accessors ----

  /// For HSRA: payload[0:8] = batch_number (also = total sent when EOS).
  int get hsraBatchNumber {
    if (payload.length < 8) return 0;
    final bd = ByteData.view(payload.buffer, payload.offsetInBytes, 8);
    return bdGetUint64(bd, 0, Endian.big);
  }

  /// For HSRA: payload[8:16] = message_count; 0 means end-of-stream.
  int get hsraMessageCount {
    if (payload.length < 16) return 0;
    final bd = ByteData.view(payload.buffer, payload.offsetInBytes + 8, 8);
    return bdGetUint64(bd, 0, Endian.big);
  }

  bool get hsraIsEndOfStream => hsraMessageCount == 0;

  /// Splits the HSRA payload into raw MESSAGE frame blobs using the offsets table.
  /// Each blob is a complete, re-signed MESSAGE frame encrypted with the current CK.
  List<Uint8List> get hsraExtractMessages {
    final count = hsraMessageCount;
    if (count == 0 || payload.length < 16 + count * 8) return [];

    final offsets = <int>[];
    for (var i = 0; i < count; i++) {
      final bd = ByteData.view(
          payload.buffer, payload.offsetInBytes + 16 + i * 8, 8);
      offsets.add(bdGetUint64(bd, 0, Endian.big));
    }

    final blobStart = 16 + count * 8;
    final blob = payload.sublist(blobStart);
    final result = <Uint8List>[];

    for (var i = 0; i < offsets.length; i++) {
      final start = offsets[i];
      final end = (i + 1 < offsets.length) ? offsets[i + 1] : blob.length;
      if (start >= blob.length || end > blob.length || start > end) continue;
      result.add(Uint8List.fromList(blob.sublist(start, end)));
    }
    return result;
  }
}

/// Parse a complete frame from [raw] bytes.
/// Returns null if the bytes are too short or malformed.
ParsedFrame? tryParseFrame(Uint8List raw) {
  if (raw.length < SgtpConstants.headerSize + SgtpConstants.signatureSize) {
    return null;
  }

  final bd = ByteData.view(raw.buffer, raw.offsetInBytes);

  final roomUUID     = Uint8List.fromList(raw.sublist(0, 16));
  final receiverUUID = Uint8List.fromList(raw.sublist(16, 32));
  final senderUUID   = Uint8List.fromList(raw.sublist(32, 48));
  final version      = bd.getUint16(48, Endian.big);
  final packetType   = bd.getUint16(50, Endian.big);
  final payloadLength = bd.getUint32(52, Endian.big);
  final timestamp    = bdGetUint64(bd, 56, Endian.big);

  final totalExpected =
      SgtpConstants.headerSize + payloadLength + SgtpConstants.signatureSize;

  if (raw.length < totalExpected) return null;
  if (payloadLength > SgtpConstants.maxPayloadSize) return null;

  final payload = Uint8List.fromList(
      raw.sublist(SgtpConstants.headerSize,
          SgtpConstants.headerSize + payloadLength));
  final signature =
      Uint8List.fromList(raw.sublist(totalExpected - 64, totalExpected));
  final frameRaw =
      Uint8List.fromList(raw.sublist(0, totalExpected));

  return ParsedFrame(
    roomUUID:      roomUUID,
    receiverUUID:  receiverUUID,
    senderUUID:    senderUUID,
    version:       version,
    packetType:    packetType,
    payloadLength: payloadLength,
    timestamp:     timestamp,
    payload:       payload,
    signature:     signature,
    raw:           frameRaw,
  );
}

/// Tries to extract one complete frame from the buffer.
({ParsedFrame frame, int bytesConsumed})? tryExtractFrame(List<int> buffer) {
  if (buffer.length < SgtpConstants.headerSize + SgtpConstants.signatureSize) {
    return null;
  }

  final bd = ByteData.view(
      Uint8List.fromList(buffer.sublist(0, SgtpConstants.headerSize)).buffer);
  final payloadLength = bd.getUint32(52, Endian.big);

  if (payloadLength > SgtpConstants.maxPayloadSize) return null;

  final totalExpected =
      SgtpConstants.headerSize + payloadLength + SgtpConstants.signatureSize;

  if (buffer.length < totalExpected) return null;

  final rawBytes = Uint8List.fromList(buffer.sublist(0, totalExpected));
  final frame = tryParseFrame(rawBytes);
  if (frame == null) return null;

  return (frame: frame, bytesConsumed: totalExpected);
}

// Extension added: CHAT_REQUEST metadata accessors (new extended format)
extension ParsedFrameChatRequestMeta on ParsedFrame {
  /// Parse chat name from extended CHAT_REQUEST payload.
  /// Returns null if the payload is old-format (no metadata section).
  String? get chatRequestName {
    try {
      final count = chatRequestCount;
      int off = 8 + count * 16; // skip count + UUIDs
      if (off + 4 > payload.length) return null;
      final bd = ByteData.view(payload.buffer, payload.offsetInBytes);
      final nameLen = bd.getUint32(off, Endian.big); off += 4;
      if (nameLen == 0 || off + nameLen > payload.length) return null;
      return utf8.decode(payload.sublist(off, off + nameLen));
    } catch (_) { return null; }
  }

  /// Parse avatar bytes from extended CHAT_REQUEST payload.
  Uint8List? get chatRequestAvatar {
    try {
      final count = chatRequestCount;
      int off = 8 + count * 16;
      if (off + 4 > payload.length) return null;
      final bd = ByteData.view(payload.buffer, payload.offsetInBytes);
      final nameLen = bd.getUint32(off, Endian.big); off += 4;
      off += nameLen; // skip name bytes
      if (off + 4 > payload.length) return null;
      final avatarLen = bd.getUint32(off, Endian.big); off += 4;
      if (avatarLen == 0 || off + avatarLen > payload.length) return null;
      return Uint8List.fromList(payload.sublist(off, off + avatarLen));
    } catch (_) { return null; }
  }
}
