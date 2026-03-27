import 'dart:convert';
import 'dart:typed_data';

/// Result of parsing an OpenSSH private key
typedef OpenSshKeyData = ({Uint8List seed, Uint8List publicKey});

/// Parses an OpenSSH private key file (bytes) and returns the Ed25519 seed and public key.
///
/// Supports the standard "-----BEGIN OPENSSH PRIVATE KEY-----" format.
OpenSshKeyData parseOpenSshPrivateKey(Uint8List fileBytes) {
  // Decode the file as text
  final text = utf8.decode(fileBytes);
  final lines = text.split('\n').map((l) => l.trim()).toList();

  // Find base64 body between header and footer
  final buffer = StringBuffer();
  bool inKey = false;
  for (final line in lines) {
    if (line == '-----BEGIN OPENSSH PRIVATE KEY-----') {
      inKey = true;
      continue;
    }
    if (line == '-----END OPENSSH PRIVATE KEY-----') {
      break;
    }
    if (inKey && line.isNotEmpty) {
      buffer.write(line);
    }
  }

  final decoded = base64.decode(buffer.toString());
  return _parseOpenSshBinary(decoded);
}

OpenSshKeyData _parseOpenSshBinary(Uint8List data) {
  // Magic: "openssh-key-v1\0"
  const magic = 'openssh-key-v1\x00';
  final magicBytes = ascii.encode(magic);
  for (var i = 0; i < magicBytes.length; i++) {
    if (data[i] != magicBytes[i]) {
      throw FormatException('Not an OpenSSH private key file (bad magic)');
    }
  }

  var offset = magicBytes.length;
  final reader = _BinaryReader(data);
  reader.offset = offset;

  // cipher name (string)
  reader.readString(); // ciphername
  // kdf name (string)
  reader.readString(); // kdfname
  // kdf options (string = length-prefixed)
  reader.readString(); // kdf options
  // number of keys (uint32)
  final numKeys = reader.readUint32();
  if (numKeys != 1) {
    throw FormatException('Expected 1 key, got $numKeys');
  }

  // public key block (length-prefixed)
  final pubKeyBlock = reader.readString();
  // private block (length-prefixed)
  final privateBlock = reader.readString();

  // Parse public key block to get public key bytes
  final pubReader = _BinaryReader(pubKeyBlock);
  final keyType = utf8.decode(pubReader.readString()); // "ssh-ed25519"
  if (keyType != 'ssh-ed25519') {
    throw FormatException('Expected ssh-ed25519 key type, got $keyType');
  }
  final publicKey = pubReader.readString(); // 32 bytes

  // Parse private block
  final privReader = _BinaryReader(privateBlock);
  final check1 = privReader.readUint32();
  final check2 = privReader.readUint32();
  if (check1 != check2) {
    throw FormatException('Private key check values do not match (wrong passphrase?)');
  }

  final privKeyType = utf8.decode(privReader.readString()); // "ssh-ed25519"
  if (privKeyType != 'ssh-ed25519') {
    throw FormatException('Expected ssh-ed25519 in private block, got $privKeyType');
  }

  privReader.readString(); // public key (32 bytes, again)
  final privKey64 = privReader.readString(); // 64 bytes: seed (32) + public key (32)

  if (privKey64.length < 32) {
    throw FormatException('Private key field too short: ${privKey64.length}');
  }

  final seed = Uint8List.fromList(privKey64.sublist(0, 32));

  return (seed: seed, publicKey: Uint8List.fromList(publicKey));
}

/// Parses an OpenSSH public key string line (e.g., "ssh-ed25519 BASE64 comment")
/// and returns the 32-byte Ed25519 public key.
Uint8List parseOpenSshPublicKeyLine(String line) {
  final parts = line.trim().split(RegExp(r'\s+'));
  if (parts.length < 2) {
    throw FormatException('Invalid OpenSSH public key line');
  }
  if (parts[0] != 'ssh-ed25519') {
    throw FormatException('Expected ssh-ed25519, got ${parts[0]}');
  }

  final decoded = base64.decode(parts[1]);
  final reader = _BinaryReader(decoded);

  final keyType = utf8.decode(reader.readString());
  if (keyType != 'ssh-ed25519') {
    throw FormatException('Expected ssh-ed25519 in public key blob');
  }

  final pubKey = reader.readString();
  if (pubKey.length != 32) {
    throw FormatException('Expected 32-byte public key, got ${pubKey.length}');
  }

  return Uint8List.fromList(pubKey);
}

/// Tries to parse a public key file (both OpenSSH text format and raw 32-byte binary).
/// Returns null on failure.
Uint8List? tryParsePublicKeyFile(Uint8List fileBytes) {
  // Try raw 32-byte binary
  if (fileBytes.length == 32) {
    return Uint8List.fromList(fileBytes);
  }

  // Try OpenSSH text format
  try {
    final text = utf8.decode(fileBytes, allowMalformed: true);
    final lines = text.split('\n');
    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.startsWith('ssh-ed25519 ')) {
        return parseOpenSshPublicKeyLine(trimmed);
      }
    }
  } catch (_) {
    // ignore
  }

  return null;
}

/// Simple binary reader with a mutable offset
class _BinaryReader {
  final Uint8List data;
  int offset = 0;

  _BinaryReader(this.data);

  int readUint32() {
    if (offset + 4 > data.length) {
      throw FormatException('Unexpected end of data reading uint32 at $offset');
    }
    final view = ByteData.view(data.buffer, data.offsetInBytes + offset, 4);
    final value = view.getUint32(0, Endian.big);
    offset += 4;
    return value;
  }

  Uint8List readString() {
    final length = readUint32();
    if (offset + length > data.length) {
      throw FormatException(
          'Unexpected end of data reading string of length $length at offset $offset');
    }
    final result = Uint8List.fromList(data.sublist(offset, offset + length));
    offset += length;
    return result;
  }
}
