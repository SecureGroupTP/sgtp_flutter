import 'dart:typed_data';

/// dart2js does not support ByteData.getUint64 / ByteData.setUint64.
/// These helpers read/write 64-bit big-endian integers via two 32-bit accesses,
/// which works on every platform including web.
///
/// JS integers are IEEE-754 doubles with 53 bits of precision (up to ~9e15).
/// SGTP timestamps (~1.7e12 ms) fit exactly; 64-bit nonces lose the top ~11
/// bits on web but still have 53 bits of randomness.

int bdGetUint64(ByteData bd, int offset, Endian endian) {
  if (endian == Endian.big) {
    final hi = bd.getUint32(offset, Endian.big);
    final lo = bd.getUint32(offset + 4, Endian.big);
    return hi * 0x100000000 + lo;
  } else {
    final lo = bd.getUint32(offset, Endian.little);
    final hi = bd.getUint32(offset + 4, Endian.little);
    return hi * 0x100000000 + lo;
  }
}

void bdSetUint64(ByteData bd, int offset, int value, Endian endian) {
  final hi = value ~/ 0x100000000;
  final lo = value & 0xFFFFFFFF;
  if (endian == Endian.big) {
    bd.setUint32(offset, hi, Endian.big);
    bd.setUint32(offset + 4, lo, Endian.big);
  } else {
    bd.setUint32(offset, lo, Endian.little);
    bd.setUint32(offset + 4, hi, Endian.little);
  }
}
