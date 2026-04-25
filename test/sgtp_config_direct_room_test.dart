import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sgtp_flutter/features/messaging/domain/entities/sgtp_config.dart';

void main() {
  SgtpConfig buildConfig() {
    return SgtpConfig(
      accountId: 'acc-1',
      deviceId: 'device-1',
      serverAddr: 'localhost:9000',
      roomUUID: Uint8List(16),
      identityKeyPair: SimpleKeyPairData(
        Uint8List(32),
        publicKey: SimplePublicKey(Uint8List(32), type: KeyPairType.ed25519),
        type: KeyPairType.ed25519,
      ),
      myPublicKey: Uint8List(32),
    );
  }

  test('copyWithDirectRoom enables direct-message mode', () {
    final cfg = buildConfig();

    final next = cfg.copyWithDirectRoom(
      isDirectMessage: true,
      directPeerPublicKeyHex: ('C' * 64),
      bootstrapDirectRoom: true,
    );

    expect(next.isDirectMessage, isTrue);
    expect(next.directPeerPublicKeyHex, 'C' * 64);
    expect(next.bootstrapDirectRoom, isTrue);
  });

  test('copyWithDirectRoom keeps existing direct peer when omitted', () {
    final cfg = buildConfig().copyWithDirectRoom(
      isDirectMessage: true,
      directPeerPublicKeyHex: 'a' * 64,
    );

    final next = cfg.copyWithDirectRoom(isDirectMessage: true);

    expect(next.isDirectMessage, isTrue);
    expect(next.directPeerPublicKeyHex, 'a' * 64);
  });

  test('copyWithDirectRoom can disable direct-message mode', () {
    final cfg = buildConfig().copyWithDirectRoom(
      isDirectMessage: true,
      directPeerPublicKeyHex: 'b' * 64,
    );

    final next = cfg.copyWithDirectRoom(isDirectMessage: true);

    expect(next.isDirectMessage, isTrue);
    expect(next.directPeerPublicKeyHex, 'b' * 64);
  });
}
