import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/uuid_v7.dart';
import '../../../data/sgtp_client.dart';
import '../chat/chat_bloc.dart';
import '../chat/chat_event.dart';
import 'rooms_event.dart';
import 'rooms_state.dart';

// Internal event — triggers a rebuild when any ChatBloc status changes.
class _RoomsRefresh extends RoomsEvent {
  const _RoomsRefresh();
  @override
  List<Object?> get props => [];
}

class RoomsBloc extends Bloc<RoomsEvent, RoomsState> {
  final SgtpConfig _baseConfig;
  final Map<String, String> _nicknames;
  Uint8List? _userAvatar;
  final Map<String, StreamSubscription<dynamic>> _chatSubs = {};

  RoomsBloc({
    required SgtpConfig baseConfig,
    required Map<String, String> nicknames,
    required String serverAddress,
    Uint8List? userAvatar,
  })  : _baseConfig = baseConfig,
        _nicknames = nicknames,
        _userAvatar = userAvatar,
        super(RoomsState(serverAddress: serverAddress)) {
    on<RoomsCreateRoom>(_onCreate);
    on<RoomsJoinRoom>(_onJoin);
    on<RoomsRemoveRoom>(_onRemove);
    on<_RoomsRefresh>(_onRefresh);
  }

  /// Update the user avatar in all active room blocs.
  void setUserAvatar(Uint8List? avatar) {
    _userAvatar = avatar;
    for (final room in state.rooms) {
      room.chatBloc.add(ChatSetUserAvatar(avatar));
    }
  }

  // ── Event handlers ────────────────────────────────────────────────────────

  void _onCreate(RoomsCreateRoom event, Emitter<RoomsState> emit) {
    final roomUUID = generateUUIDv7();
    _addRoom(roomUUID, emit);
  }

  void _onJoin(RoomsJoinRoom event, Emitter<RoomsState> emit) {
    final hexClean = event.uuidHex.trim().replaceAll('-', '');
    if (hexClean.length != 32) {
      emit(state.copyWith(error: 'UUID must be 32 hex chars (without dashes)'));
      return;
    }
    try {
      final bytes = hexToBytes(hexClean);
      _addRoom(bytes, emit);
    } catch (_) {
      emit(state.copyWith(error: 'Invalid UUID format'));
    }
  }

  void _addRoom(Uint8List roomUUID, Emitter<RoomsState> emit) {
    final hexUUID = uuidBytesToHex(roomUUID);
    if (state.rooms.any((r) => r.roomUUID == hexUUID)) {
      emit(state.copyWith(error: 'Already joined this room'));
      return;
    }

    final config   = _baseConfig.copyWithRoomUUID(roomUUID);
    final chatBloc = ChatBloc()
      ..add(ChatConnect(config, nicknames: _nicknames));

    // Push user avatar into the new bloc
    if (_userAvatar != null) {
      chatBloc.add(ChatSetUserAvatar(_userAvatar));
    }

    _chatSubs[hexUUID] = chatBloc.stream.listen((_) {
      add(const _RoomsRefresh());
    });

    final entry = RoomEntry(roomUUID: hexUUID, chatBloc: chatBloc);
    emit(state.copyWith(
      rooms: [...state.rooms, entry],
      clearError: true,
    ));
  }

  void _onRemove(RoomsRemoveRoom event, Emitter<RoomsState> emit) {
    _chatSubs[event.roomUUID]?.cancel();
    _chatSubs.remove(event.roomUUID);
    final room = state.rooms.where((r) => r.roomUUID == event.roomUUID).firstOrNull;
    room?.chatBloc.close();
    emit(state.copyWith(
      rooms: state.rooms.where((r) => r.roomUUID != event.roomUUID).toList(),
      clearError: true,
    ));
  }

  void _onRefresh(_RoomsRefresh event, Emitter<RoomsState> emit) {
    emit(state.copyWith());
  }

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  @override
  Future<void> close() async {
    for (final sub in _chatSubs.values) {
      await sub.cancel();
    }
    for (final room in state.rooms) {
      await room.chatBloc.close();
    }
    return super.close();
  }
}
