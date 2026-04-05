import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/sgtp_transport.dart';
import '../../../data/repositories/settings_repository.dart';
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
  final String _accountId;
  SgtpConfig _baseConfig;
  final Map<String, String> _nicknames;
  Map<String, Uint8List> _contactAvatarsByPub = const {};
  Uint8List? _userAvatar;
  final Map<String, StreamSubscription<dynamic>> _chatSubs = {};
  final SettingsRepository _settings = SettingsRepository();

  RoomsBloc({
    required String accountId,
    required SgtpConfig baseConfig,
    required Map<String, String> nicknames,
    required String serverAddress,
    Uint8List? userAvatar,
  })  : _baseConfig = baseConfig,
        _accountId = accountId,
        _nicknames = nicknames,
        _userAvatar = userAvatar,
        super(RoomsState(serverAddress: serverAddress)) {
    on<RoomsCreateRoom>(_onCreate);
    on<RoomsJoinRoom>(_onJoin);
    on<RoomsRemoveRoom>(_onRemove);
    on<RoomsUpdateWhitelist>(_onUpdateWhitelist);
    on<RoomsUpdateNicknames>(_onUpdateNicknames);
    on<RoomsUpdateContactAvatars>(_onUpdateContactAvatars);
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

  Future<void> _onCreate(
      RoomsCreateRoom event, Emitter<RoomsState> emit) async {
    final roomUUID = generateUUIDv7();
    final configOverride = await _configOverrideForTarget(
      serverAddress: event.serverAddress,
      transport: event.transport,
      useTls: event.useTls,
    );
    _addRoom(roomUUID, emit, configOverride: configOverride);
  }

  Future<void> _onJoin(RoomsJoinRoom event, Emitter<RoomsState> emit) async {
    final hexClean = event.uuidHex.trim().replaceAll('-', '');
    if (hexClean.length != 32) {
      emit(state.copyWith(error: 'UUID must be 32 hex chars (without dashes)'));
      return;
    }
    try {
      final bytes = hexToBytes(hexClean);
      final configOverride = await _configOverrideForTarget(
        serverAddress: event.serverAddress,
        transport: event.transport,
        useTls: event.useTls,
      );
      _addRoom(
        bytes,
        emit,
        configOverride: configOverride,
        openOffline: event.openOffline,
      );
    } catch (_) {
      emit(state.copyWith(error: 'Invalid UUID format'));
    }
  }

  Future<SgtpConfig?> _configOverrideForTarget({
    String? serverAddress,
    SgtpTransportFamily? transport,
    bool? useTls,
  }) async {
    final addr = serverAddress?.trim();
    if ((transport == null || useTls == null) &&
        addr != null &&
        addr.isNotEmpty) {
      final resolved = await _resolveServerTransport(addr);
      transport ??= resolved?.$1;
      useTls ??= resolved?.$2;
    }

    if ((addr == null || addr.isEmpty) && transport == null && useTls == null) {
      return null;
    }

    var cfg = _baseConfig;
    if (addr != null && addr.isNotEmpty) {
      cfg = cfg.copyWith(serverAddr: addr);
    }
    if (transport != null) {
      cfg = cfg.copyWith(transport: transport);
    }
    if (useTls != null) {
      cfg = cfg.copyWith(useTls: useTls);
    }
    return cfg;
  }

  Future<(SgtpTransportFamily, bool)?> _resolveServerTransport(
      String serverAddress) async {
    final target = _normalizeAddress(serverAddress);
    if (target.isEmpty) return null;
    final nodes = await _settings.loadNodes();
    for (final node in nodes) {
      if (_normalizeAddress(node.chatAddress) == target) {
        return (node.transport, node.useTls);
      }
    }
    return null;
  }

  String _normalizeAddress(String raw) {
    return raw
        .trim()
        .replaceAll(RegExp(r'^https?://', caseSensitive: false), '')
        .replaceAll(RegExp(r'^wss?://', caseSensitive: false), '')
        .toLowerCase();
  }

  void _onUpdateWhitelist(
      RoomsUpdateWhitelist event, Emitter<RoomsState> emit) {
    // Update base config so future rooms use the new whitelist.
    _baseConfig = _baseConfig.copyWith(whitelist: event.whitelist);
    // Hot-push to all already-running rooms — no reconnect needed.
    for (final room in state.rooms) {
      room.chatBloc.add(ChatUpdateWhitelist(event.whitelist));
    }
  }

  void _onUpdateNicknames(
      RoomsUpdateNicknames event, Emitter<RoomsState> emit) {
    // Store locally so new rooms created later get the latest nicknames.
    _nicknames
      ..clear()
      ..addAll(event.nicknames);
    // Hot-push to all already-running rooms so nick appears immediately.
    for (final room in state.rooms) {
      room.chatBloc.add(ChatUpdateNicknames(event.nicknames));
    }
  }

  void _onUpdateContactAvatars(
      RoomsUpdateContactAvatars event, Emitter<RoomsState> emit) {
    _contactAvatarsByPub = Map<String, Uint8List>.from(event.avatarsByPubkey);
    for (final room in state.rooms) {
      room.chatBloc.add(ChatUpdateContactAvatars(event.avatarsByPubkey));
    }
  }

  void _addRoom(Uint8List roomUUID, Emitter<RoomsState> emit,
      {SgtpConfig? configOverride, bool openOffline = false}) {
    final hexUUID = uuidBytesToHex(roomUUID);
    if (state.rooms.any((r) => r.roomUUID == hexUUID)) {
      emit(state.copyWith(error: 'Already joined this room'));
      return;
    }

    final config = (configOverride ?? _baseConfig)
        .copyWith(accountId: _accountId)
        .copyWithRoomUUID(roomUUID);
    final chatBloc = ChatBloc(accountId: _accountId)
      ..add(openOffline
          ? ChatOpenOffline(config, nicknames: _nicknames)
          : ChatConnect(config, nicknames: _nicknames));

    // Push user avatar into the new bloc
    if (_userAvatar != null) {
      chatBloc.add(ChatSetUserAvatar(_userAvatar));
    }
    if (_contactAvatarsByPub.isNotEmpty) {
      chatBloc.add(ChatUpdateContactAvatars(_contactAvatarsByPub));
    }

    _chatSubs[hexUUID] = chatBloc.stream.listen((_) {
      add(const _RoomsRefresh());
    });

    final entry = RoomEntry(
      roomUUID: hexUUID,
      serverAddress: config.serverAddr,
      chatBloc: chatBloc,
    );
    emit(state.copyWith(
      rooms: [...state.rooms, entry],
      clearError: true,
    ));
  }

  Future<void> _onRemove(RoomsRemoveRoom event, Emitter<RoomsState> emit) async {
    await _chatSubs[event.roomUUID]?.cancel();
    _chatSubs.remove(event.roomUUID);
    final room =
        state.rooms.where((r) => r.roomUUID == event.roomUUID).firstOrNull;
    if (room != null) {
      room.chatBloc.add(const ChatDisconnect());
      await room.chatBloc.close();
    }
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
