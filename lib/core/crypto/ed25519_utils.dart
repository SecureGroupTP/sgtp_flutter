import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';

/// Sign a frame: signs all bytes except the last 64 (signature slot),
/// then fills the last 64 bytes with the signature.
/// Returns a new Uint8List with the signature filled in.
Future<Uint8List> signFrame(Uint8List frame, SimpleKeyPairData keyPair) async {
  if (frame.length < 64) {
    throw ArgumentError('Frame too short to sign: ${frame.length}');
  }

  final algorithm = Ed25519();
  // Sign everything except the last 64 bytes
  final dataToSign = frame.sublist(0, frame.length - 64);
  final signature = await algorithm.sign(dataToSign, keyPair: keyPair);

  final result = Uint8List.fromList(frame);
  final sigBytes = signature.bytes;
  if (sigBytes.length != 64) {
    throw StateError('Ed25519 signature should be 64 bytes, got ${sigBytes.length}');
  }
  result.setRange(frame.length - 64, frame.length, sigBytes);
  return result;
}

/// Verify the Ed25519 signature of a frame.
/// The signature is the last 64 bytes; the signed data is everything before.
Future<bool> verifyFrame(Uint8List frame, Uint8List pubKeyBytes) async {
  if (frame.length < 64) return false;
  if (pubKeyBytes.length != 32) return false;

  try {
    final algorithm = Ed25519();
    final publicKey = SimplePublicKey(pubKeyBytes, type: KeyPairType.ed25519);
    final dataToVerify = frame.sublist(0, frame.length - 64);
    final sigBytes = frame.sublist(frame.length - 64);
    final signature = Signature(sigBytes, publicKey: publicKey);
    return await algorithm.verify(dataToVerify, signature: signature);
  } catch (_) {
    return false;
  }
}

/// Construct an Ed25519 SimpleKeyPairData from a 32-byte seed and 32-byte public key.
SimpleKeyPairData makeKeyPair(Uint8List seed32, Uint8List pub32) {
  return SimpleKeyPairData(
    seed32,
    publicKey: SimplePublicKey(pub32, type: KeyPairType.ed25519),
    type: KeyPairType.ed25519,
  );
}
