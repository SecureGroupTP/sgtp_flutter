import 'dart:typed_data';
import 'dart:convert' show utf8;
import 'package:cryptography/cryptography.dart';

/// Generate an ephemeral X25519 key pair.
Future<SimpleKeyPair> generateEphemeralKeyPair() async {
  final algorithm = X25519();
  return algorithm.newKeyPair();
}

/// Extract the 32-byte public key bytes from an X25519 key pair.
Future<Uint8List> extractPublicKeyBytes(SimpleKeyPair kp) async {
  final publicKey = await kp.extractPublicKey();
  return Uint8List.fromList(publicKey.bytes);
}

/// Compute a shared secret from our X25519 key pair and the peer's 32-byte public key.
/// Returns the 32-byte shared secret.
Future<Uint8List> computeSharedSecret(
    SimpleKeyPair myKp, Uint8List theirPubBytes) async {
  final algorithm = X25519();
  final theirPublicKey = SimplePublicKey(theirPubBytes, type: KeyPairType.x25519);
  final sharedSecretKey = await algorithm.sharedSecretKey(
    keyPair: myKp,
    remotePublicKey: theirPublicKey,
  );
  final bytes = await sharedSecretKey.extractBytes();
  return Uint8List.fromList(bytes);
}

/// Derive a uniformly-random 32-byte key from the raw X25519 shared secret.
///
/// Use this instead of using the ECDH output directly as a symmetric key.
Future<Uint8List> deriveSharedKey(Uint8List rawSecret, Uint8List salt) async {
  final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
  final output = await hkdf.deriveKey(
    secretKey: SecretKey(rawSecret),
    nonce: salt,
    info: utf8.encode('sgtp-shared-key-v1'),
  );
  return Uint8List.fromList(await output.extractBytes());
}
