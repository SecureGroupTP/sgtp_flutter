import 'dart:typed_data';

class ContactsServerSearchHit {
  const ContactsServerSearchHit({
    required this.username,
    required this.pubkeyHex,
    required this.fullname,
  });

  final String username;
  final String pubkeyHex;
  final String fullname;
}

class ContactsServerSearchHitUiModel {
  const ContactsServerSearchHitUiModel({
    required this.username,
    required this.pubkeyHex,
    required this.fullname,
    required this.suggestedName,
  });

  final String username;
  final String pubkeyHex;
  final String fullname;
  final String suggestedName;
}

enum ContactsFriendStatus {
  none,
  pendingOutgoing,
  pendingIncoming,
  friend,
  rejected,
}

class ContactsContactUiModel {
  const ContactsContactUiModel({
    required this.hexKey,
    required this.shortKey,
    required this.displayName,
    required this.friendStatus,
    this.username,
    this.avatarBytes,
    this.roomUUIDHex,
  });

  final String hexKey;
  final String shortKey;
  final String displayName;
  final String? username;
  final Uint8List? avatarBytes;
  final ContactsFriendStatus friendStatus;
  final String? roomUUIDHex;
}

class ContactsIncomingRequestUiModel {
  const ContactsIncomingRequestUiModel({
    required this.peerHex,
    required this.shortKey,
    required this.displayName,
    this.username,
    this.avatarBytes,
  });

  final String peerHex;
  final String shortKey;
  final String displayName;
  final String? username;
  final Uint8List? avatarBytes;
}
