import 'dart:convert';
import 'dart:typed_data';

class AuthChallengeValidationException implements Exception {
  final String message;

  const AuthChallengeValidationException(this.message);

  @override
  String toString() => message;
}

class AuthChallengeValidator {
  static const String expectedType = 'authenticationChallenge';

  const AuthChallengeValidator._();

  static void validate(
    Uint8List payload, {
    required Uint8List expectedClientNonce,
    DateTime? now,
  }) {
    final reader = _CborReader(payload);
    final challenge = reader.readAuthChallenge();
    if (!reader.isAtEnd) {
      throw const AuthChallengeValidationException(
        'Authentication challenge contains trailing CBOR data',
      );
    }

    if (challenge.type != expectedType) {
      throw AuthChallengeValidationException(
        'Unexpected authentication challenge type: ${challenge.type}',
      );
    }

    final currentTime = (now ?? DateTime.now()).toUtc().microsecondsSinceEpoch;
    if (challenge.expirationTimestamp < 0 ||
        challenge.expirationTimestamp < currentTime) {
      throw const AuthChallengeValidationException(
        'Authentication challenge has expired',
      );
    }

    if (!_bytesEqual(challenge.clientNonce, expectedClientNonce)) {
      throw const AuthChallengeValidationException(
        'Authentication challenge clientNonce mismatch',
      );
    }
  }

  static bool _bytesEqual(Uint8List left, Uint8List right) {
    if (left.length != right.length) return false;
    for (var i = 0; i < left.length; i++) {
      if (left[i] != right[i]) return false;
    }
    return true;
  }
}

class _ParsedAuthChallenge {
  final String type;
  final int expirationTimestamp;
  final int serverNonce;
  final Uint8List clientNonce;

  const _ParsedAuthChallenge({
    required this.type,
    required this.expirationTimestamp,
    required this.serverNonce,
    required this.clientNonce,
  });
}

class _CborReader {
  final Uint8List _bytes;
  int _offset = 0;

  _CborReader(this._bytes);

  bool get isAtEnd => _offset == _bytes.length;

  _ParsedAuthChallenge readAuthChallenge() {
    final initialByte = _readByte();
    final majorType = initialByte >> 5;
    final additionalInfo = initialByte & 0x1f;
    if (majorType != 5) {
      throw const AuthChallengeValidationException(
        'Authentication challenge must be a CBOR map',
      );
    }

    final seenKeys = <String>{};
    String? type;
    int? expirationTimestamp;
    int? serverNonce;
    Uint8List? clientNonce;

    void readPair() {
      final key = _readTextString();
      if (!seenKeys.add(key)) {
        throw AuthChallengeValidationException(
          'Authentication challenge contains duplicate key: $key',
        );
      }

      switch (key) {
        case 'type':
          type = _readTextString();
          return;
        case 'expirationTimestamp':
          expirationTimestamp = _readUint();
          return;
        case 'clientNonce':
          clientNonce = _readByteString();
          return;
        case 'serverNonce':
          serverNonce = _readUint();
          return;
        default:
          _skipItem();
      }
    }

    if (additionalInfo == 31) {
      while (!_peekBreak()) {
        readPair();
      }
      _offset++;
    } else {
      final pairCount = _readArgument(additionalInfo);
      for (var i = 0; i < pairCount; i++) {
        readPair();
      }
    }

    if (type == null) {
      throw const AuthChallengeValidationException(
        'Authentication challenge is missing type',
      );
    }
    if (expirationTimestamp == null) {
      throw const AuthChallengeValidationException(
        'Authentication challenge is missing expirationTimestamp',
      );
    }
    if (clientNonce == null) {
      throw const AuthChallengeValidationException(
        'Authentication challenge is missing clientNonce',
      );
    }
    if (serverNonce == null) {
      throw const AuthChallengeValidationException(
        'Authentication challenge is missing serverNonce',
      );
    }

    return _ParsedAuthChallenge(
      type: type!,
      expirationTimestamp: expirationTimestamp!,
      serverNonce: serverNonce!,
      clientNonce: clientNonce!,
    );
  }

  String _readTextString() {
    final initialByte = _readByte();
    final majorType = initialByte >> 5;
    final additionalInfo = initialByte & 0x1f;
    if (majorType != 3) {
      throw const AuthChallengeValidationException(
        'Authentication challenge key/value must be a CBOR text string',
      );
    }
    final bytes = _readStringBytes(additionalInfo, expectMajorType: 3);
    try {
      return utf8.decode(bytes, allowMalformed: false);
    } on FormatException {
      throw const AuthChallengeValidationException(
        'Authentication challenge contains invalid UTF-8 text',
      );
    }
  }

  Uint8List _readByteString() {
    final initialByte = _readByte();
    final majorType = initialByte >> 5;
    final additionalInfo = initialByte & 0x1f;
    if (majorType != 2) {
      throw const AuthChallengeValidationException(
        'Authentication challenge clientNonce must be a CBOR byte string',
      );
    }
    return _readStringBytes(additionalInfo, expectMajorType: 2);
  }

  Uint8List _readStringBytes(
    int additionalInfo, {
    required int expectMajorType,
  }) {
    if (additionalInfo == 31) {
      final out = BytesBuilder(copy: false);
      while (!_peekBreak()) {
        final chunkInitialByte = _readByte();
        final chunkMajorType = chunkInitialByte >> 5;
        final chunkAdditionalInfo = chunkInitialByte & 0x1f;
        if (chunkMajorType != expectMajorType || chunkAdditionalInfo == 31) {
          throw const AuthChallengeValidationException(
            'Authentication challenge contains invalid chunked string',
          );
        }
        final chunkLength = _readArgument(chunkAdditionalInfo);
        out.add(_readBytes(chunkLength));
      }
      _offset++;
      return out.takeBytes();
    }

    final length = _readArgument(additionalInfo);
    return _readBytes(length);
  }

  int _readUint() {
    final initialByte = _readByte();
    final majorType = initialByte >> 5;
    final additionalInfo = initialByte & 0x1f;
    if (majorType != 0) {
      throw const AuthChallengeValidationException(
        'Authentication challenge expirationTimestamp must be a CBOR uint',
      );
    }
    return _readArgument(additionalInfo);
  }

  void _skipItem() {
    final initialByte = _readByte();
    _skipItemWithInitialByte(initialByte);
  }

  void _skipItemWithInitialByte(int initialByte) {
    final majorType = initialByte >> 5;
    final additionalInfo = initialByte & 0x1f;

    switch (majorType) {
      case 0:
      case 1:
        _readArgument(additionalInfo);
        return;
      case 2:
      case 3:
        _skipString(additionalInfo, majorType);
        return;
      case 4:
        _skipArray(additionalInfo);
        return;
      case 5:
        _skipMap(additionalInfo);
        return;
      case 6:
        _readArgument(additionalInfo);
        _skipItem();
        return;
      case 7:
        _skipSimple(additionalInfo);
        return;
      default:
        throw const AuthChallengeValidationException('Unsupported CBOR type');
    }
  }

  void _skipString(int additionalInfo, int majorType) {
    if (additionalInfo == 31) {
      while (!_peekBreak()) {
        final chunkInitialByte = _readByte();
        final chunkMajorType = chunkInitialByte >> 5;
        final chunkAdditionalInfo = chunkInitialByte & 0x1f;
        if (chunkMajorType != majorType || chunkAdditionalInfo == 31) {
          throw const AuthChallengeValidationException(
            'Authentication challenge contains invalid chunked string',
          );
        }
        final chunkLength = _readArgument(chunkAdditionalInfo);
        _readBytes(chunkLength);
      }
      _offset++;
      return;
    }

    final length = _readArgument(additionalInfo);
    _readBytes(length);
  }

  void _skipArray(int additionalInfo) {
    if (additionalInfo == 31) {
      while (!_peekBreak()) {
        _skipItem();
      }
      _offset++;
      return;
    }

    final length = _readArgument(additionalInfo);
    for (var i = 0; i < length; i++) {
      _skipItem();
    }
  }

  void _skipMap(int additionalInfo) {
    if (additionalInfo == 31) {
      while (!_peekBreak()) {
        _skipItem();
        if (_peekBreak()) {
          throw const AuthChallengeValidationException(
            'Authentication challenge contains malformed CBOR map',
          );
        }
        _skipItem();
      }
      _offset++;
      return;
    }

    final length = _readArgument(additionalInfo);
    for (var i = 0; i < length; i++) {
      _skipItem();
      _skipItem();
    }
  }

  void _skipSimple(int additionalInfo) {
    switch (additionalInfo) {
      case 24:
        _ensureAvailable(1);
        _offset += 1;
        return;
      case 25:
        _ensureAvailable(2);
        _offset += 2;
        return;
      case 26:
        _ensureAvailable(4);
        _offset += 4;
        return;
      case 27:
        _ensureAvailable(8);
        _offset += 8;
        return;
      case 31:
        throw const AuthChallengeValidationException(
          'Unexpected CBOR break outside container',
        );
      default:
        return;
    }
  }

  bool _peekBreak() {
    _ensureAvailable(1);
    return _bytes[_offset] == 0xff;
  }

  int _readArgument(int additionalInfo) {
    switch (additionalInfo) {
      case < 24:
        return additionalInfo;
      case 24:
        return _readByte();
      case 25:
        final bytes = _readBytes(2);
        return (bytes[0] << 8) | bytes[1];
      case 26:
        final bytes = _readBytes(4);
        return (bytes[0] << 24) | (bytes[1] << 16) | (bytes[2] << 8) | bytes[3];
      case 27:
        final bytes = _readBytes(8);
        var value = 0;
        for (final byte in bytes) {
          value = (value << 8) | byte;
        }
        if (value < 0) {
          throw const AuthChallengeValidationException(
            'Authentication challenge integer is out of supported range',
          );
        }
        return value;
      case 31:
        throw const AuthChallengeValidationException(
          'Unexpected indefinite-length marker',
        );
      default:
        throw const AuthChallengeValidationException(
          'Authentication challenge contains unsupported CBOR argument',
        );
    }
  }

  int _readByte() {
    _ensureAvailable(1);
    return _bytes[_offset++];
  }

  Uint8List _readBytes(int length) {
    _ensureAvailable(length);
    final out = Uint8List.sublistView(_bytes, _offset, _offset + length);
    _offset += length;
    return out;
  }

  void _ensureAvailable(int length) {
    if (_offset + length > _bytes.length) {
      throw const AuthChallengeValidationException(
        'Authentication challenge contains truncated CBOR data',
      );
    }
  }
}
