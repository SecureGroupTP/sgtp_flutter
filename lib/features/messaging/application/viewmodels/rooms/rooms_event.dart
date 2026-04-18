import 'dart:typed_data';
import 'package:equatable/equatable.dart';
import 'package:sgtp_flutter/core/sgtp_transport.dart';

abstract class RoomsEvent extends Equatable {
  const RoomsEvent();
  @override
  List<Object?> get props => [];
}

/// Creates a new room with a freshly generated UUID v7.
class RoomsCreateRoom extends RoomsEvent {
  /// Optional — if provided, this room will connect to that server instead of
  /// the default one.
  final String? serverAddress;
  final SgtpTransportFamily? transport;
  final bool? useTls;
  const RoomsCreateRoom({this.serverAddress, this.transport, this.useTls});
  @override
  List<Object?> get props => [serverAddress, transport, useTls];
}

/// Joins an existing room by its hex UUID string (32 chars, no dashes).
/// [serverAddress] is optional — if provided (e.g. from a QR/base64 invite),
/// this room will connect to that server instead of the default one.
class RoomsJoinRoom extends RoomsEvent {
  final String uuidHex;
  final String? serverAddress;
  final SgtpTransportFamily? transport;
  final bool? useTls;
  final bool isDirectMessage;
  final bool bootstrapDirectRoom;
  final String? directPeerPublicKeyHex;
  const RoomsJoinRoom(this.uuidHex,
      {this.serverAddress,
      this.transport,
      this.useTls,
      this.isDirectMessage = false,
      this.bootstrapDirectRoom = false,
      this.directPeerPublicKeyHex});
  @override
  List<Object?> get props => [
        uuidHex,
        serverAddress,
        transport,
        useTls,
        isDirectMessage,
        bootstrapDirectRoom,
        directPeerPublicKeyHex,
      ];
}

/// Disconnects and removes a room from the list.
class RoomsRemoveRoom extends RoomsEvent {
  final String roomUUID;
  final String serverAddress;
  const RoomsRemoveRoom(this.roomUUID, {required this.serverAddress});
  @override
  List<Object?> get props => [roomUUID, serverAddress];
}

/// Deletes a chat locally (metadata + history) and removes it from active rooms.
class RoomsDeleteRoomLocal extends RoomsEvent {
  final String roomUUID;
  final String serverAddress;
  const RoomsDeleteRoomLocal(this.roomUUID, {required this.serverAddress});
  @override
  List<Object?> get props => [roomUUID, serverAddress];
}

/// Hot-updates the peer whitelist across all active rooms and the base config.
/// Call this whenever the contacts list changes so new contacts can join
/// existing rooms without a reconnect.
class RoomsUpdateWhitelist extends RoomsEvent {
  final Set<String> whitelist;
  const RoomsUpdateWhitelist(this.whitelist);
  @override
  List<Object?> get props => [whitelist];
}

/// Hot-updates nicknames (ed25519PubHex → name) in all active rooms.
/// Call this together with RoomsUpdateWhitelist when contacts change.
class RoomsUpdateNicknames extends RoomsEvent {
  final Map<String, String> nicknames;
  const RoomsUpdateNicknames(this.nicknames);
  @override
  List<Object?> get props => [nicknames];
}

/// Hot-updates contact avatars (ed25519PubHex -> avatar bytes)
/// in all active rooms.
class RoomsUpdateContactAvatars extends RoomsEvent {
  final Map<String, Uint8List> avatarsByPubkey;
  const RoomsUpdateContactAvatars(this.avatarsByPubkey);
  @override
  List<Object?> get props => [avatarsByPubkey];
}

/// Load stored chats from disk for the current account/server.
class RoomsLoadStoredChats extends RoomsEvent {
  const RoomsLoadStoredChats();
}

/// Sync stored chat metadata from active rooms (called after state changes).
class RoomsSyncStoredChats extends RoomsEvent {
  const RoomsSyncStoredChats();
}

/// Delete a stored chat and its history from disk.
class RoomsDeleteStoredChat extends RoomsEvent {
  final String uuid;
  final String serverAddress;
  const RoomsDeleteStoredChat(this.uuid, {required this.serverAddress});
  @override
  List<Object?> get props => [uuid, serverAddress];
}

/// Upsert (create or update) a stored chat entry.
class RoomsUpsertChat extends RoomsEvent {
  final String uuid;
  final String? serverAddress;
  final String? name;
  final Uint8List? avatarBytes;
  const RoomsUpsertChat(this.uuid,
      {this.serverAddress, this.name, this.avatarBytes});
  @override
  List<Object?> get props => [uuid, serverAddress, name, avatarBytes];
}

/// Mute/unmute notifications for a chat (local-only).
class RoomsSetChatMuted extends RoomsEvent {
  final String uuid;
  final String serverAddress;
  final bool muted;
  const RoomsSetChatMuted(
    this.uuid, {
    required this.serverAddress,
    required this.muted,
  });
  @override
  List<Object?> get props => [uuid, serverAddress, muted];
}
