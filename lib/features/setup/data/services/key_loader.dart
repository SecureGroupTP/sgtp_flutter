import 'dart:typed_data';
import 'package:sgtp_flutter/core/openssh_parser.dart';

/// Loads and parses cryptographic keys from file bytes.
class KeyLoader {
  KeyLoader._();

  /// Parse an OpenSSH private key file and return seed + public key.
  static Future<({Uint8List seed, Uint8List publicKey})> loadPrivateKey(
      Uint8List fileBytes) async {
    return parseOpenSshPrivateKey(fileBytes);
  }

  /// Parse multiple public key files and return valid 32-byte Ed25519 public keys.
  /// Invalid/unparseable files are silently skipped.
  static Future<List<Uint8List>> loadContactKeyFiles(
      List<Uint8List> fileBytesList) async {
    final result = <Uint8List>[];
    for (final fileBytes in fileBytesList) {
      final key = tryParsePublicKeyFile(fileBytes);
      if (key != null) {
        result.add(key);
      }
    }
    return result;
  }
}
