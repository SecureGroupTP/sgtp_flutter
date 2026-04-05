import 'dart:typed_data';

/// A whitelist entry: a trusted peer's public key + editable display name.
class WhitelistEntry {
  final Uint8List bytes;
  final String name;

  WhitelistEntry({required this.bytes, required this.name});

  String get hexKey =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  WhitelistEntry copyWithName(String newName) =>
      WhitelistEntry(bytes: bytes, name: newName);
}

/// Cached profile data fetched from the userdir service.
class ContactProfile {
  final String pubkeyHex;
  final String? username;
  final String? fullname;
  final Uint8List? avatarBytes;
  final String avatarSha256Hex;
  final int updatedAt;

  const ContactProfile({
    required this.pubkeyHex,
    this.username,
    this.fullname,
    this.avatarBytes,
    required this.avatarSha256Hex,
    required this.updatedAt,
  });
}

enum FriendStatus {
  none,
  pendingOutgoing,
  pendingIncoming,
  friend,
  rejected,
}

class FriendStateRecord {
  final String peerPubkeyHex;
  final String status;
  final String? roomUUIDHex;
  final int updatedAt;

  const FriendStateRecord({
    required this.peerPubkeyHex,
    required this.status,
    required this.roomUUIDHex,
    required this.updatedAt,
  });

  FriendStatus get statusEnum {
    for (final s in FriendStatus.values) {
      if (s.name == status) return s;
    }
    return FriendStatus.none;
  }

  FriendStateRecord copyWith({
    String? status,
    String? roomUUIDHex,
    int? updatedAt,
  }) {
    return FriendStateRecord(
      peerPubkeyHex: peerPubkeyHex,
      status: status ?? this.status,
      roomUUIDHex: roomUUIDHex ?? this.roomUUIDHex,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}
