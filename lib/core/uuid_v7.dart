import 'dart:math';
import 'dart:typed_data';

/// Generates a UUID v7 as a 16-byte Uint8List.
///
/// Structure:
/// - Bits [0:48]   = Unix timestamp in milliseconds (big-endian)
/// - Bits [48:52]  = version = 7
/// - Bits [52:64]  = random (12 bits)
/// - Bits [64:66]  = variant = 0b10
/// - Bits [66:128] = random (62 bits)
Uint8List generateUUIDv7() {
  final now = DateTime.now().millisecondsSinceEpoch;
  final rng = Random.secure();

  final bytes = Uint8List(16);
  final data = ByteData.view(bytes.buffer);

  // Bytes 0-5: 48-bit timestamp (ms)
  // Write as high 32 bits then low 16 bits
  final tsHigh = (now >> 16) & 0xFFFFFFFF;
  final tsLow = now & 0xFFFF;
  data.setUint32(0, tsHigh, Endian.big);
  data.setUint16(4, tsLow, Endian.big);

  // Byte 6: version (4 bits) | random (4 bits upper nibble of rand12)
  final rand12 = rng.nextInt(0x1000); // 12 bits
  bytes[6] = (0x70) | ((rand12 >> 8) & 0x0F);
  bytes[7] = rand12 & 0xFF;

  // Bytes 8-15: variant (2 bits = 0b10) | random (62 bits)
  bytes[8] = 0x80 | rng.nextInt(64); // 0b10xxxxxx
  bytes[9] = rng.nextInt(256);
  bytes[10] = rng.nextInt(256);
  bytes[11] = rng.nextInt(256);
  bytes[12] = rng.nextInt(256);
  bytes[13] = rng.nextInt(256);
  bytes[14] = rng.nextInt(256);
  bytes[15] = rng.nextInt(256);

  return bytes;
}

/// Format UUID bytes as hex string (no dashes)
String uuidBytesToHex(Uint8List bytes) {
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

/// Parse hex string to UUID bytes
Uint8List hexToBytes(String hex) {
  if (hex.length % 2 != 0) {
    throw ArgumentError('Hex string must have even length');
  }
  final result = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < result.length; i++) {
    result[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return result;
}

/// Compare two Uint8List lexicographically. Returns negative if a < b, 0 if equal, positive if a > b.
int compareBytes(Uint8List a, Uint8List b) {
  final len = a.length < b.length ? a.length : b.length;
  for (var i = 0; i < len; i++) {
    if (a[i] != b[i]) return a[i] - b[i];
  }
  return a.length - b.length;
}
