import 'package:equatable/equatable.dart';

abstract class RoomsEvent extends Equatable {
  const RoomsEvent();
  @override
  List<Object?> get props => [];
}

/// Creates a new room with a freshly generated UUID v7.
class RoomsCreateRoom extends RoomsEvent {
  const RoomsCreateRoom();
}

/// Joins an existing room by its hex UUID string (32 chars, no dashes).
/// [serverAddress] is optional — if provided (e.g. from a QR/base64 invite),
/// this room will connect to that server instead of the default one.
class RoomsJoinRoom extends RoomsEvent {
  final String uuidHex;
  final String? serverAddress;
  const RoomsJoinRoom(this.uuidHex, {this.serverAddress});
  @override
  List<Object?> get props => [uuidHex, serverAddress];
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
