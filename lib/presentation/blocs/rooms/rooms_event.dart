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
class RoomsJoinRoom extends RoomsEvent {
  final String uuidHex;
  const RoomsJoinRoom(this.uuidHex);
  @override
  List<Object?> get props => [uuidHex];
}

/// Disconnects and removes a room from the list.
class RoomsRemoveRoom extends RoomsEvent {
  final String roomUUID;
  const RoomsRemoveRoom(this.roomUUID);
  @override
  List<Object?> get props => [roomUUID];
}
