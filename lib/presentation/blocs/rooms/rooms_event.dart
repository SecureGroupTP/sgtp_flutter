import 'dart:typed_data';
import 'package:equatable/equatable.dart';
import '../../../core/sgtp_transport.dart';

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
  final bool openOffline;
  const RoomsJoinRoom(this.uuidHex,
      {this.serverAddress,
      this.transport,
      this.useTls,
      this.openOffline = false});
  @override
  List<Object?> get props =>
      [uuidHex, serverAddress, transport, useTls, openOffline];
}

/// Disconnects and removes a room from the list.
class RoomsRemoveRoom extends RoomsEvent {
  final String roomUUID;
  const RoomsRemoveRoom(this.roomUUID);
  @override
  List<Object?> get props => [roomUUID];
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
