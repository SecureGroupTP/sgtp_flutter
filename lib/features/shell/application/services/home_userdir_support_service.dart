import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:sgtp_flutter/features/setup/domain/entities/contact_directory_models.dart';

class HomeUserDirSupportService {
  static const List<int> _directMessageRoomNamespace = <int>[
    0x73,
    0x67,
    0x74,
    0x70,
    0x2d,
    0x64,
    0x6d,
    0x2d,
    0x72,
    0x6f,
    0x6f,
    0x6d,
    0x2d,
    0x76,
    0x31,
  ];

  String? normalizeUsername(String? raw) {
    if (raw == null) return null;
    final stripped = raw.trim().replaceFirst(RegExp(r'^@+'), '');
    final sanitized = stripped
        .replaceAll(RegExp(r'[^A-Za-z0-9_]'), '')
        .substring(
          0,
          stripped.replaceAll(RegExp(r'[^A-Za-z0-9_]'), '').length.clamp(0, 32),
        );
    if (sanitized.isEmpty) return null;
    return sanitized;
  }

  String? buildUsername(String rawUsername) {
    final normalized = normalizeUsername(rawUsername);
    if (normalized == null || normalized.isEmpty) return null;
    return '@$normalized';
  }

  String buildProfileFingerprint({
    required Uint8List publicKey,
    required String nickname,
    required String username,
    required Uint8List? userAvatar,
  }) {
    final normalizedUsername = buildUsername(username) ?? '';
    final avatarLen = userAvatar?.length ?? 0;
    final pubHex =
        publicKey.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '$pubHex|$normalizedUsername|$nickname|$avatarLen';
  }

  Uint8List hexToBytes32(String hex) {
    final clean = hex.trim().toLowerCase();
    return Uint8List.fromList(List<int>.generate(
      32,
      (i) => int.parse(clean.substring(i * 2, i * 2 + 2), radix: 16),
    ));
  }

  Future<String> buildDirectMessageRoomUUIDHex({
    required Uint8List myPublicKey,
    required Uint8List peerPublicKey,
  }) async {
    final left = Uint8List.fromList(myPublicKey);
    final right = Uint8List.fromList(peerPublicKey);
    final sorted = _compareBytes(left, right) <= 0
        ? <Uint8List>[left, right]
        : <Uint8List>[right, left];
    final payload = Uint8List(
      _directMessageRoomNamespace.length + sorted[0].length + sorted[1].length,
    );
    payload.setRange(
        0, _directMessageRoomNamespace.length, _directMessageRoomNamespace);
    payload.setRange(
      _directMessageRoomNamespace.length,
      _directMessageRoomNamespace.length + sorted[0].length,
      sorted[0],
    );
    payload.setRange(
      _directMessageRoomNamespace.length + sorted[0].length,
      payload.length,
      sorted[1],
    );
    final digest = await Sha256().hash(payload);
    final bytes =
        Uint8List.fromList(digest.bytes.take(16).toList(growable: false));
    bytes[6] = (bytes[6] & 0x0f) | 0x70;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  int _compareBytes(Uint8List left, Uint8List right) {
    final limit = left.length < right.length ? left.length : right.length;
    for (var i = 0; i < limit; i++) {
      final diff = left[i] - right[i];
      if (diff != 0) return diff;
    }
    return left.length - right.length;
  }

  Map<String, Uint8List> buildContactAvatarsByPubkey({
    required List<WhitelistEntry> whitelist,
    required Map<String, ContactProfile> contactProfiles,
  }) {
    final allowed = whitelist.map((e) => e.hexKey).toSet();
    final out = <String, Uint8List>{};
    for (final entry in contactProfiles.entries) {
      if (!allowed.contains(entry.key)) continue;
      final avatar = entry.value.avatarBytes;
      if (avatar != null && avatar.isNotEmpty) {
        out[entry.key] = avatar;
      }
    }
    return out;
  }
}
