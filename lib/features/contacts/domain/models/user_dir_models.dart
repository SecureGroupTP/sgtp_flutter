import 'dart:typed_data';

class UserDirFriendStatus {
  static const int pendingOutgoing = 1;
  static const int pendingIncoming = 2;
  static const int friend = 3;
  static const int rejected = 4;
}

class UserDirFriendState {
  final Uint8List peerPubkey;
  final int status;
  final Uint8List? roomUUID;

  const UserDirFriendState({
    required this.peerPubkey,
    required this.status,
    required this.roomUUID,
  });

  String get peerPubkeyHex =>
      peerPubkey.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  String? get roomUUIDHex => roomUUID == null
      ? null
      : roomUUID!.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

class UserDirFriendNotify {
  final int eventType; // 1=request created, 2=request answered, 3=dm ready
  final int status;
  final Uint8List actorPubkey;
  final Uint8List? roomUUID;

  const UserDirFriendNotify({
    required this.eventType,
    required this.status,
    required this.actorPubkey,
    required this.roomUUID,
  });

  String get actorPubkeyHex =>
      actorPubkey.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

/// Lightweight profile data returned by GET_META / NOTIFY.
class UserDirMeta {
  final Uint8List pubkey;
  final String username;
  final String fullname;
  final Uint8List avatarSha256; // 32 bytes
  final int updatedAt; // unix seconds

  const UserDirMeta({
    required this.pubkey,
    required this.username,
    required this.fullname,
    required this.avatarSha256,
    required this.updatedAt,
  });

  String get pubkeyHex =>
      pubkey.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  String get avatarSha256Hex =>
      avatarSha256.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

/// Full profile including avatar bytes, returned by GET_PROFILE.
class UserDirProfile extends UserDirMeta {
  final Uint8List avatarBytes;

  const UserDirProfile({
    required super.pubkey,
    required super.username,
    required super.fullname,
    required super.avatarSha256,
    required super.updatedAt,
    required this.avatarBytes,
  });
}
