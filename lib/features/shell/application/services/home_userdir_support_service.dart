import 'dart:typed_data';

import 'package:sgtp_flutter/features/setup/domain/entities/contact_directory_models.dart';

class HomeUserDirSupportService {
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

  Map<String, Uint8List> buildContactAvatarsByPubkey({
    required List<ContactEntry> contacts,
    required Map<String, ContactProfile> contactProfiles,
  }) {
    final allowed = contacts.map((e) => e.hexKey).toSet();
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

