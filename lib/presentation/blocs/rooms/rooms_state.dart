import '../chat/chat_bloc.dart';

class RoomEntry {
  final String roomUUID; // hex, 32 chars
  final ChatBloc chatBloc;

  RoomEntry({required this.roomUUID, required this.chatBloc});

  /// Short label shown in the rooms list.
  String get label => roomUUID.substring(0, 8);
}

/// Not Equatable — uses reference equality so every copyWith() triggers a rebuild.
class RoomsState {
  final List<RoomEntry> rooms;
  final String serverAddress;
  final String? error;

  const RoomsState({
    this.rooms = const [],
    this.serverAddress = '',
    this.error,
  });

  RoomsState copyWith({
    List<RoomEntry>? rooms,
    String? serverAddress,
    String? error,
    bool clearError = false,
  }) {
    return RoomsState(
      rooms:         rooms         ?? this.rooms,
      serverAddress: serverAddress ?? this.serverAddress,
      error:         clearError ? null : (error ?? this.error),
    );
  }
}
