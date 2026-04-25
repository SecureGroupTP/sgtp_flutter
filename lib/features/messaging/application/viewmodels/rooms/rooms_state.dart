import 'package:sgtp_flutter/features/messaging/application/viewmodels/chat/chat_bloc.dart';
import 'package:sgtp_flutter/features/messaging/application/models/messaging_models.dart';

class RoomEntry {
  final String roomUUID; // hex, 32 chars
  final String serverAddress; // host:port (chat)
  final ChatBloc chatBloc;

  RoomEntry({
    required this.roomUUID,
    required this.serverAddress,
    required this.chatBloc,
  });

  /// Short label shown in the rooms list.
  String get label => roomUUID.substring(0, 8);
}

/// Not Equatable — uses reference equality so every copyWith() triggers a rebuild.
class RoomsState {
  final List<RoomEntry> rooms;
  final String serverAddress;
  final String? error;
  final List<ChatMetadata> storedChats;

  const RoomsState({
    this.rooms = const [],
    this.serverAddress = '',
    this.error,
    this.storedChats = const [],
  });

  RoomsState copyWith({
    List<RoomEntry>? rooms,
    String? serverAddress,
    String? error,
    bool clearError = false,
    List<ChatMetadata>? storedChats,
  }) {
    return RoomsState(
      rooms:         rooms         ?? this.rooms,
      serverAddress: serverAddress ?? this.serverAddress,
      error:         clearError ? null : (error ?? this.error),
      storedChats:   storedChats   ?? this.storedChats,
    );
  }
}
