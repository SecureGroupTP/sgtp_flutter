import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../data/sgtp_client.dart';
import '../../../domain/entities/message.dart';
import 'chat_event.dart';
import 'chat_state.dart';

class ChatBloc extends Bloc<ChatEvent, ChatState> {
  SgtpClient? _client;
  StreamSubscription<SgtpEvent>? _eventSub;

  ChatBloc() : super(const ChatState()) {
    on<ChatConnect>(_onConnect);
    on<ChatSendMessage>(_onSendMessage);
    on<ChatSendImage>(_onSendImage);
    on<ChatSendVideo>(_onSendVideo);
    on<ChatSendVoice>(_onSendVoice);
    on<ChatDisconnect>(_onDisconnect);
    on<ChatInternalSgtpEvent>(_onSgtpEvent);
  }

  Future<void> _onConnect(ChatConnect event, Emitter<ChatState> emit) async {
    await _eventSub?.cancel();
    await _client?.close();

    final client = SgtpClient(event.config);
    _client = client;

    final pubHex = event.config.myPublicKey
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();

    emit(state.copyWith(
      status: ChatStatus.connecting,
      messages: [],
      peerUUIDs: [],
      isMaster: false,
      myPublicKeyHex: pubHex,
      clearError: true,
    ));

    _eventSub = client.events.listen(
      (sgtpEvent) => add(ChatInternalSgtpEvent(sgtpEvent)),
      onError: (e) => add(ChatInternalSgtpEvent(SgtpError(error: e.toString()))),
    );

    await client.connect();
  }

  Future<void> _onSendMessage(ChatSendMessage event, Emitter<ChatState> emit) async {
    if (_client == null || state.status != ChatStatus.ready) return;
    await _client!.sendMessage(event.text);
  }

  Future<void> _onSendImage(ChatSendImage event, Emitter<ChatState> emit) async {
    if (_client == null || state.status != ChatStatus.ready) return;
    await _client!.sendImage(event.bytes, event.name, event.mime);
  }

  Future<void> _onSendVideo(ChatSendVideo event, Emitter<ChatState> emit) async {
    if (_client == null || state.status != ChatStatus.ready) return;
    await _client!.sendVideo(event.bytes, event.name, event.mime);
  }

  Future<void> _onSendVoice(ChatSendVoice event, Emitter<ChatState> emit) async {
    if (_client == null || state.status != ChatStatus.ready) return;
    await _client!.sendVoice(event.bytes, event.mime);
  }

  Future<void> _onDisconnect(ChatDisconnect event, Emitter<ChatState> emit) async {
    await _client?.disconnect();
    await _eventSub?.cancel();
    _eventSub = null;
    emit(state.copyWith(status: ChatStatus.disconnected));
  }

  void _onSgtpEvent(ChatInternalSgtpEvent event, Emitter<ChatState> emit) {
    final sgtpEvent = event.sgtpEvent;
    switch (sgtpEvent) {
      case SgtpConnecting():
        emit(state.copyWith(
          status: ChatStatus.connecting,
          roomUUID: _client?.roomUUIDHex ?? '',
        ));

      case SgtpHandshaking():
        emit(state.copyWith(
          status: ChatStatus.handshaking,
          myUUID: _client?.myUUIDHex ?? '',
          roomUUID: _client?.roomUUIDHex ?? '',  // фикс: UUID комнаты сразу
        ));

      case SgtpReady(:final isMaster, :final roomUUIDHex):
        emit(state.copyWith(
          status: ChatStatus.ready,
          isMaster: isMaster,
          roomUUID: roomUUIDHex,
          myUUID: _client?.myUUIDHex ?? '',
          peerUUIDs: _client?.peerUUIDs ?? [],
        ));

      case SgtpMessageReceived(:final message):
        final updated = List<ChatMessage>.from(state.messages)..add(message);
        emit(state.copyWith(messages: updated));

      case SgtpPeerJoined(:final peerUUID):
        if (!state.peerUUIDs.contains(peerUUID)) {
          emit(state.copyWith(peerUUIDs: [...state.peerUUIDs, peerUUID]));
        }

      case SgtpPeerLeft(:final peerUUID):
        emit(state.copyWith(
          peerUUIDs: state.peerUUIDs.where((id) => id != peerUUID).toList(),
        ));

      case SgtpError(:final error):
        emit(state.copyWith(status: ChatStatus.error, errorMessage: error));

      case SgtpDisconnected():
        emit(state.copyWith(status: ChatStatus.disconnected));
    }
  }

  @override
  Future<void> close() async {
    await _eventSub?.cancel();
    await _client?.close();
    return super.close();
  }
}