import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:sgtp_flutter/core/uint64_utils.dart';

/// Convert a uint64 nonce to a 12-byte nonce for ChaCha20-Poly1305.
/// Format: [0, 0, 0, 0, b7, b6, b5, b4, b3, b2, b1, b0] (big-endian 8 bytes, prefixed with 4 zeros)
Uint8List makeNonce12(int nonce64) {
  final nonce = Uint8List(12);
  final bd = ByteData.view(nonce.buffer);
  // First 4 bytes are zero
  bd.setUint32(0, 0, Endian.big);
  // Last 8 bytes are the nonce in big-endian
  bdSetUint64(bd, 4, nonce64, Endian.big);
  return nonce;
}

/// Encrypt plaintext with ChaCha20-Poly1305.
/// Returns ciphertext + 16-byte Poly1305 tag (plaintext.length + 16 bytes).
Future<Uint8List> encrypt(
    Uint8List plaintext, Uint8List key32, int nonce64) async {
  final algorithm = Chacha20.poly1305Aead();
  final secretKey = SecretKey(key32);
  final nonce = makeNonce12(nonce64);

  final secretBox = await algorithm.encrypt(
    plaintext,
    secretKey: secretKey,
    nonce: nonce,
  );

  // SecretBox: ciphertext + mac (16 bytes)
  final result = Uint8List(secretBox.cipherText.length + secretBox.mac.bytes.length);
  result.setRange(0, secretBox.cipherText.length, secretBox.cipherText);
  result.setRange(
      secretBox.cipherText.length, result.length, secretBox.mac.bytes);
  return result;
}

/// Decrypt ciphertext+tag (last 16 bytes are Poly1305 tag) with ChaCha20-Poly1305.
/// Returns plaintext.
Future<Uint8List> decrypt(
    Uint8List ciphertextAndTag, Uint8List key32, int nonce64) async {
  if (ciphertextAndTag.length < 16) {
    throw ArgumentError('Ciphertext too short (must include 16-byte tag)');
  }

  final algorithm = Chacha20.poly1305Aead();
  final secretKey = SecretKey(key32);
  final nonce = makeNonce12(nonce64);

  final cipherText =
      ciphertextAndTag.sublist(0, ciphertextAndTag.length - 16);
  final macBytes =
      ciphertextAndTag.sublist(ciphertextAndTag.length - 16);

  final secretBox = SecretBox(
    cipherText,
    nonce: nonce,
    mac: Mac(macBytes),
  );

  final plaintext = await algorithm.decrypt(secretBox, secretKey: secretKey);
  return Uint8List.fromList(plaintext);
}
