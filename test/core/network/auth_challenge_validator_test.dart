import 'dart:typed_data';

import 'package:cbor/cbor.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sgtp_flutter/core/network/auth_challenge_validator.dart';

void main() {
  group('AuthChallengeValidator', () {
    final nonce = Uint8List.fromList([1, 2, 3, 4]);
    final now = DateTime.utc(2026, 4, 14, 12, 0);
    final futureUs = now.add(const Duration(minutes: 5)).microsecondsSinceEpoch;

    test('accepts valid authentication challenge', () {
      final payload = Uint8List.fromList(
        cbor.encode(
          CborMap({
            CborString('type'): CborString('authenticationChallenge'),
            CborString('expirationTimestamp'): CborInt(BigInt.from(futureUs)),
            CborString('serverNonce'): CborInt(BigInt.from(123)),
            CborString('clientNonce'): CborBytes(nonce),
          }),
        ),
      );

      expect(
        () => AuthChallengeValidator.validate(
          payload,
          expectedClientNonce: nonce,
          now: now,
        ),
        returnsNormally,
      );
    });

    test('accepts challenge with full uint64 server nonce', () {
      final payload = Uint8List.fromList(
        cbor.encode(
          CborMap({
            CborString('type'): CborString('authenticationChallenge'),
            CborString('expirationTimestamp'): CborInt(BigInt.from(futureUs)),
            CborString('serverNonce'): CborInt(
              BigInt.parse('18446744073709551615'),
            ),
            CborString('clientNonce'): CborBytes(nonce),
          }),
        ),
      );

      expect(
        () => AuthChallengeValidator.validate(
          payload,
          expectedClientNonce: nonce,
          now: now,
        ),
        returnsNormally,
      );
    });

    test('rejects unexpected type', () {
      final payload = Uint8List.fromList(
        cbor.encode(
          CborMap({
            CborString('type'): CborString('groupInvite'),
            CborString('expirationTimestamp'): CborInt(BigInt.from(futureUs)),
            CborString('clientNonce'): CborBytes(nonce),
          }),
        ),
      );

      expect(
        () => AuthChallengeValidator.validate(
          payload,
          expectedClientNonce: nonce,
          now: now,
        ),
        throwsA(isA<AuthChallengeValidationException>()),
      );
    });

    test('rejects client nonce mismatch', () {
      final payload = Uint8List.fromList(
        cbor.encode(
          CborMap({
            CborString('type'): CborString('authenticationChallenge'),
            CborString('expirationTimestamp'): CborInt(BigInt.from(futureUs)),
            CborString('clientNonce'): CborBytes(Uint8List.fromList([9, 9])),
          }),
        ),
      );

      expect(
        () => AuthChallengeValidator.validate(
          payload,
          expectedClientNonce: nonce,
          now: now,
        ),
        throwsA(isA<AuthChallengeValidationException>()),
      );
    });

    test('rejects duplicate type keys in raw CBOR', () {
      final payload = Uint8List.fromList([
        0xa4,
        0x64,
        0x74,
        0x79,
        0x70,
        0x65,
        0x76,
        0x67,
        0x72,
        0x6f,
        0x75,
        0x70,
        0x49,
        0x6e,
        0x76,
        0x69,
        0x74,
        0x65,
        0x64,
        0x74,
        0x79,
        0x70,
        0x65,
        0x77,
        0x61,
        0x75,
        0x74,
        0x68,
        0x65,
        0x6e,
        0x74,
        0x69,
        0x63,
        0x61,
        0x74,
        0x69,
        0x6f,
        0x6e,
        0x43,
        0x68,
        0x61,
        0x6c,
        0x6c,
        0x65,
        0x6e,
        0x67,
        0x65,
        0x73,
        0x65,
        0x78,
        0x70,
        0x69,
        0x72,
        0x61,
        0x74,
        0x69,
        0x6f,
        0x6e,
        0x54,
        0x69,
        0x6d,
        0x65,
        0x73,
        0x74,
        0x61,
        0x6d,
        0x70,
        0x1b,
        (futureUs >> 56) & 0xff,
        (futureUs >> 48) & 0xff,
        (futureUs >> 40) & 0xff,
        (futureUs >> 32) & 0xff,
        (futureUs >> 24) & 0xff,
        (futureUs >> 16) & 0xff,
        (futureUs >> 8) & 0xff,
        futureUs & 0xff,
        0x6b,
        0x63,
        0x6c,
        0x69,
        0x65,
        0x6e,
        0x74,
        0x4e,
        0x6f,
        0x6e,
        0x63,
        0x65,
        0x44,
        0x01,
        0x02,
        0x03,
        0x04,
      ]);

      expect(
        () => AuthChallengeValidator.validate(
          payload,
          expectedClientNonce: nonce,
          now: now,
        ),
        throwsA(isA<AuthChallengeValidationException>()),
      );
    });
  });
}
