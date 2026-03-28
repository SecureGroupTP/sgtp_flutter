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
      status:       ChatStatus.connecting,
      messages:     [],
      peerUUIDs:    [],
      peerNicknames: {},
      isMaster:     false,
      myPublicKeyHex: pubHex,
      nicknames:    event.nicknames,
      clearError: true,
    ));

    _eventSub = client.events.listen(
      (sgtpEvent) => add(ChatInternalSgtpEvent(sgtpEvent)),
      onError: (e) => add(ChatInternalSgtpEvent(SgtpError(error: e.toString()))),
    );

    await client.connect();
  }

  Future<void> _onSendMessage(
      ChatSendMessage event, Emitter<ChatState> emit) async {
    if (_client == null || state.status != ChatStatus.ready) return;
    await _client!.sendMessage(event.text);
  }

  Future<void> _onSendImage(
      ChatSendImage event, Emitter<ChatState> emit) async {
    print('📸 [Bloc] _onSendImage called: ${event.name} (${event.bytes.length} bytes, mime: ${event.mime})');
    if (_client == null) {
      print('❌ [Bloc] Client is null');
      return;
    }
    if (state.status != ChatStatus.ready) {
      print('⚠️ [Bloc] Status is ${state.status}, not ready');
      return;
    }
    try {
      print('📤 [Bloc] Sending image to client...');
      await _client!.sendImage(event.bytes, event.name, event.mime);
      print('✅ [Bloc] Image sent successfully');
    } catch (e) {
      print('❌ [Bloc] Error sending image: $e');
    }
  }

  Future<void> _onSendVideo(
      ChatSendVideo event, Emitter<ChatState> emit) async {
    if (_client == null || state.status != ChatStatus.ready) return;
    await _client!.sendVideo(event.bytes, event.name, event.mime);
  }

  Future<void> _onSendVoice(
      ChatSendVoice event, Emitter<ChatState> emit) async {
    if (_client == null || state.status != ChatStatus.ready) return;
    await _client!.sendVoice(event.bytes, event.mime);
  }

  Future<void> _onDisconnect(
      ChatDisconnect event, Emitter<ChatState> emit) async {
    await _client?.disconnect();
    await _eventSub?.cancel();
    _eventSub = null;
    emit(state.copyWith(status: ChatStatus.disconnected));
  }

  ChatMessage _createSystemMessage(String content) {
    return ChatMessage(
      id: _generateMessageId(),
      senderUUID: 'system',
      content: content,
      type: MessageType.system,
      receivedAt: DateTime.now(),
      isFromHistory: false,
      isFromMe: false,
    );
  }

  String _generateMessageId() {
    return DateTime.now().millisecondsSinceEpoch.toString().padLeft(16, '0');
  }

  void _onSgtpEvent(ChatInternalSgtpEvent event, Emitter<ChatState> emit) {
    final sgtpEvent = event.sgtpEvent;
    switch (sgtpEvent) {
      case SgtpConnecting():
        emit(state.copyWith(
          status:   ChatStatus.connecting,
          roomUUID: _client?.roomUUIDHex ?? '',
        ));

      case SgtpHandshaking():
        emit(state.copyWith(
          status:   ChatStatus.handshaking,
          myUUID:   _client?.myUUIDHex ?? '',
          roomUUID: _client?.roomUUIDHex ?? '',
        ));

      case SgtpReady(:final isMaster, :final roomUUIDHex):
        emit(state.copyWith(
          status:    ChatStatus.ready,
          isMaster:  isMaster,
          roomUUID:  roomUUIDHex,
          myUUID:    _client?.myUUIDHex ?? '',
          peerUUIDs: _client?.peerUUIDs ?? [],
        ));

      case SgtpMessageReceived(:final message):
        final updated = List<ChatMessage>.from(state.messages)..add(message);
        emit(state.copyWith(messages: updated));

      case SgtpPeerJoined(:final peerUUID, :final ed25519PubHex):
        // Resolve nickname from whitelist (ed25519PubHex → nickname)
        final nick = state.nicknames[ed25519PubHex];
        final updatedPeerNicknames = Map<String, String>.from(state.peerNicknames);
        if (nick != null) updatedPeerNicknames[peerUUID] = nick;

        // Create system message
        final displayName = nick ?? peerUUID.substring(0, 8);
        final systemMsg = _createSystemMessage('👤 $displayName joined the chat');
        final updatedMessages = List<ChatMessage>.from(state.messages)..add(systemMsg);

        // Update history
        final updatedHistory = Map<String, String>.from(state.peerNicknamesHistory);
        if (nick != null) updatedHistory[peerUUID] = nick;

        if (!state.peerUUIDs.contains(peerUUID)) {
          emit(state.copyWith(
            messages:               updatedMessages,
            peerUUIDs:              [...state.peerUUIDs, peerUUID],
            peerNicknames:          updatedPeerNicknames,
            peerNicknamesHistory:   updatedHistory,
          ));
        } else {
          emit(state.copyWith(
            messages:               updatedMessages,
            peerNicknames:          updatedPeerNicknames,
            peerNicknamesHistory:   updatedHistory,
          ));
        }

      case SgtpPeerLeft(:final peerUUID):
        // Get nickname before removing (use history if already left before)
        final nick = state.peerNicknames[peerUUID] ?? state.peerNicknamesHistory[peerUUID];
        
        // Create system message with nickname
        final displayName = nick ?? peerUUID.substring(0, 8);
        final systemMsg = _createSystemMessage('👤 $displayName left the chat');
        final updatedMessages = List<ChatMessage>.from(state.messages)..add(systemMsg);
        
        // Remove from active peers but keep in history
        final updatedNicknames = Map<String, String>.from(state.peerNicknames)
          ..remove(peerUUID);
        
        // Update history to preserve the nickname
        final updatedHistory = Map<String, String>.from(state.peerNicknamesHistory);
        if (nick != null) updatedHistory[peerUUID] = nick;
        
        emit(state.copyWith(
          messages:               updatedMessages,
          peerUUIDs:              state.peerUUIDs.where((id) => id != peerUUID).toList(),
          peerNicknames:          updatedNicknames,
          peerNicknamesHistory:   updatedHistory,
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
