import 'dart:typed_data';

class UserDirFriendStatus {
  static const int none = 0;
  static const int pendingOutgoing = 1;
  static const int pendingIncoming = 2;
  static const int friend = 3;
  static const int rejected = 4;
}

class UserDirFriendEventType {
  static const int requestReceived = 1;
  static const int requestAccepted = 2;
  static const int requestDeclined = 3;
  static const int requestCanceled = 4;
}

class UserDirFriendState {
  final Uint8List peerPubkey;
  final int status;

  /// Always null in the new protocol (DM rooms managed separately).
  final Uint8List? roomUUID;

  const UserDirFriendState({
    required this.peerPubkey,
    required this.status,
    this.roomUUID,
  });

  String get peerPubkeyHex =>
      peerPubkey.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  String? get roomUUIDHex => roomUUID == null
      ? null
      : roomUUID!.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

class UserDirFriendNotify {
  final int eventType;
  final int status;
  final Uint8List? peerPubkey;
  final Uint8List? requestId;
  final Uint8List? roomUUID;

  const UserDirFriendNotify({
    required this.eventType,
    required this.status,
    this.peerPubkey,
    this.requestId,
    this.roomUUID,
  });

  String? get peerPubkeyHex => peerPubkey == null
      ? null
      : peerPubkey!.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  String? get requestIdHex => requestId == null
      ? null
      : requestId!.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

/// Lightweight profile metadata.
class UserDirMeta {
  final Uint8List pubkey;
  final String username;

  /// Mapped from [displayName]; falls back to [username] when null.
  final String fullname;

  /// Not available from the new protocol; kept for API compatibility.
  /// Always empty (zero-length) in new implementations.
  final Uint8List avatarSha256;

  /// Unix seconds derived from lastSeenAt (microseconds ÷ 1000000).
  final int updatedAt;

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

/// Full profile including raw avatar bytes.
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
