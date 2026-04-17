import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sgtp_flutter/features/messaging/domain/entities/sgtp_config.dart';

void main() {
  SgtpConfig buildConfig({required Set<String> whitelist}) {
    return SgtpConfig(
      serverAddr: 'localhost:9000',
      roomUUID: Uint8List(16),
      identityKeyPair: SimpleKeyPairData(
        Uint8List(32),
        publicKey: SimplePublicKey(Uint8List(32), type: KeyPairType.ed25519),
        type: KeyPairType.ed25519,
      ),
      myPublicKey: Uint8List(32),
      whitelist: whitelist,
    );
  }

  test('copyWithDirectRoom narrows whitelist to direct peer', () {
    final cfg = buildConfig(whitelist: {
      'a' * 64,
      'b' * 64,
    });

    final next = cfg.copyWithDirectRoom(
      isDirectMessage: true,
      directPeerPublicKeyHex: ('C' * 64),
    );

    expect(next.isDirectMessage, isTrue);
    expect(next.whitelist, {('c' * 64)});
  });

  test('copyWithDirectRoom keeps whitelist for non-direct rooms', () {
    final cfg = buildConfig(whitelist: {
      'a' * 64,
      'b' * 64,
    });

    final next = cfg.copyWithDirectRoom(isDirectMessage: false);

    expect(next.isDirectMessage, isFalse);
    expect(next.whitelist, cfg.whitelist);
  });

  test('copyWithDirectRoom uses empty whitelist when peer is missing', () {
    final cfg = buildConfig(whitelist: {
      'a' * 64,
      'b' * 64,
    });

    final next = cfg.copyWithDirectRoom(isDirectMessage: true);

    expect(next.isDirectMessage, isTrue);
    expect(next.whitelist, isEmpty);
  });
}
