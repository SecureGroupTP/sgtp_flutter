import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter/foundation.dart' show debugPrint;

import '../../../data/repositories/chat_metadata_repository.dart';
import '../../../data/sgtp_client.dart';
import '../../../domain/entities/chat_metadata.dart';
import '../../../domain/entities/message.dart';
import 'chat_event.dart';
import 'chat_state.dart';

class ChatBloc extends Bloc<ChatEvent, ChatState> {
  SgtpClient? _client;
  StreamSubscription<SgtpEvent>? _eventSub;
  final ChatMetadataRepository _metaRepo = ChatMetadataRepository();

  // Keep last config for reconnect
  ChatConnect? _lastConnectEvent;

  ChatBloc() : super(const ChatState()) {
    on<ChatConnect>(_onConnect);
    on<ChatReconnect>(_onReconnect);
    on<ChatSendMessage>(_onSendMessage);
    on<ChatSendImage>(_onSendImage);
    on<ChatSendVideo>(_onSendVideo);
    on<ChatSendVoice>(_onSendVoice);
    on<ChatSendVideoNote>(_onSendVideoNote);
    on<ChatSendMessageRead>(_onSendMessageRead);
    on<ChatDisconnect>(_onDisconnect);
    on<ChatUpdateMetadata>(_onUpdateMetadata);
    on<ChatSetUserAvatar>(_onSetUserAvatar);
    on<ChatSetReply>(_onSetReply);
    on<ChatClearReply>(_onClearReply);
    on<ChatToggleReaction>(_onToggleReaction);
    on<ChatInternalSgtpEvent>(_onSgtpEvent);
  }

  Future<void> _onConnect(ChatConnect event, Emitter<ChatState> emit) async {
    _lastConnectEvent = event;
    await _doConnect(event, emit);
  }

  Future<void> _onReconnect(ChatReconnect event, Emitter<ChatState> emit) async {
    final last = _lastConnectEvent;
    if (last == null) return;
    await _doConnect(last, emit);
  }

  Future<void> _doConnect(ChatConnect event, Emitter<ChatState> emit) async {
    await _eventSub?.cancel();
    await _client?.close();

    // Load saved metadata from disk BEFORE creating client,
    // so we pass correct name/avatar into SgtpClient from the start.
    String chatName = event.config.chatName;
    Uint8List? chatAvatar = event.config.chatAvatarBytes;

    final roomUUIDHex = event.config.roomUUID
        .map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    final isRealRoom = !event.config.roomUUID.every((b) => b == 0);

    if (isRealRoom) {
      try {
        final saved = await _metaRepo.loadChat(roomUUIDHex);
        if (saved != null) {
          chatName   = saved.name;
          chatAvatar = saved.avatarBytes;
          debugPrint('[ChatBloc] Pre-loaded metadata: "${saved.name}"');
        }
      } catch (_) {}
    }

    // Build config with resolved metadata so the client broadcasts correct name
    final resolvedConfig = event.config.copyWithMeta(
      name:   chatName,
      avatar: chatAvatar,
    );

    final client = SgtpClient(resolvedConfig);
    // Pass user avatar to the client so it attaches it to outgoing messages
    if (state.userAvatarBytes != null) {
      client.setUserAvatar(state.userAvatarBytes);
    }
    _client = client;

    final pubHex = event.config.myPublicKey
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();

    emit(state.copyWith(
      status:          ChatStatus.connecting,
      messages:        [],
      peerUUIDs:       [],
      peerNicknames:   {},
      peerPublicKeys:  {},
      peerAvatars:     {},
      readReceipts:    {},
      isMaster:        false,
      myPublicKeyHex:  pubHex,
      nicknames:       event.nicknames,
      chatName:        chatName,
      chatAvatarBytes: chatAvatar,
      clearError:      true,
    ));

    _eventSub = client.events.listen(
      (sgtpEvent) => add(ChatInternalSgtpEvent(sgtpEvent)),
      onError: (e) => add(ChatInternalSgtpEvent(SgtpError(error: e.toString()))),
    );

    await client.connect();
  }

  Future<void> _onSendMessage(ChatSendMessage event, Emitter<ChatState> emit) async {
    if (_client == null || state.status != ChatStatus.ready) return;
    await _client!.sendMessage(
      event.text,
      replyToId:      event.replyToId,
      replyToContent: event.replyToContent,
      replyToSender:  event.replyToSender,
    );
    // Clear reply after send
    if (event.replyToId != null) emit(state.copyWith(clearReply: true));
  }

  void _onSetReply(ChatSetReply event, Emitter<ChatState> emit) {
    emit(state.copyWith(replyToMessage: event.message));
  }

  void _onClearReply(ChatClearReply event, Emitter<ChatState> emit) {
    emit(state.copyWith(clearReply: true));
  }

  void _onToggleReaction(ChatToggleReaction event, Emitter<ChatState> emit) {
    final current = Map<String, Map<String, Set<String>>>.from(state.reactions);
    final msgReactions = Map<String, Set<String>>.from(current[event.messageId] ?? {});
    final who = Set<String>.from(msgReactions[event.emoji] ?? {});
    final adding = !who.contains(state.myUUID);
    if (adding) {
      who.add(state.myUUID);
    } else {
      who.remove(state.myUUID);
    }
    if (who.isEmpty) {
      msgReactions.remove(event.emoji);
    } else {
      msgReactions[event.emoji] = who;
    }
    current[event.messageId] = msgReactions;
    final updatedMsgs = state.messages.map<ChatMessage>((m) {
      if (m.id == event.messageId) return m.copyWith(reactions: msgReactions);
      return m;
    }).toList();
    emit(state.copyWith(reactions: current, messages: updatedMsgs));
    // Send to peers
    _client?.sendReaction(event.messageId, event.emoji, adding);
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

  Future<void> _onSendVideoNote(ChatSendVideoNote event, Emitter<ChatState> emit) async {
    if (_client == null || state.status != ChatStatus.ready) return;
    await _client!.sendVideoNote(event.bytes, event.mime);
  }

  Future<void> _onSendMessageRead(ChatSendMessageRead event, Emitter<ChatState> emit) async {
    if (_client == null || state.status != ChatStatus.ready) return;
    await _client!.sendMessageRead(event.messageId);
  }

  Future<void> _onDisconnect(ChatDisconnect event, Emitter<ChatState> emit) async {
    await _client?.disconnect();
    await _eventSub?.cancel();
    _eventSub = null;
    _client   = null;
    emit(state.copyWith(status: ChatStatus.disconnected));
  }

  Future<void> _onUpdateMetadata(ChatUpdateMetadata event, Emitter<ChatState> emit) async {
    emit(state.copyWith(chatName: event.name, chatAvatarBytes: event.avatarBytes));
    await _client?.sendChatMeta(event.name, event.avatarBytes);
    final roomUUID = state.roomUUID.isNotEmpty
        ? state.roomUUID
        : (_client?.roomUUIDHex ?? '');
    await _saveMetadata(roomUUID, event.name, event.avatarBytes);
  }

  Future<void> _onSetUserAvatar(ChatSetUserAvatar event, Emitter<ChatState> emit) async {
    emit(state.copyWith(userAvatarBytes: event.avatarBytes));
    _client?.setUserAvatar(event.avatarBytes);
  }

  Future<void> _saveMetadata(String roomUUID, String name, Uint8List? avatar) async {
    if (roomUUID.isEmpty) return;
    try {
      final now      = DateTime.now();
      final existing = await _metaRepo.loadChat(roomUUID);
      final meta = ChatMetadata(
        uuid:        roomUUID,
        name:        name,
        avatarBytes: avatar,
        createdAt:   existing?.createdAt ?? now,
        updatedAt:   now,
      );
      await _metaRepo.saveChat(meta);
      debugPrint('[ChatBloc] Saved metadata for $roomUUID: "$name"');
    } catch (e) {
      debugPrint('[ChatBloc] Failed to save metadata: $e');
    }
  }

  ChatMessage _createSystemMessage(String content) => ChatMessage(
    id: DateTime.now().millisecondsSinceEpoch.toString().padLeft(16, '0'),
    senderUUID: 'system', content: content,
    type: MessageType.system, receivedAt: DateTime.now(),
    isFromHistory: false, isFromMe: false,
  );

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
          roomUUID: _client?.roomUUIDHex ?? '',
        ));

      case SgtpReady(:final isMaster, :final roomUUIDHex):
        emit(state.copyWith(
          status: ChatStatus.ready, isMaster: isMaster,
          roomUUID: roomUUIDHex, myUUID: _client?.myUUIDHex ?? '',
          peerUUIDs: _client?.peerUUIDs ?? [],
        ));
        _saveMetadata(roomUUIDHex, state.chatName, state.chatAvatarBytes);

      case SgtpMessageReceived(:final message):
        // Track peer avatar from incoming message
        Map<String, Uint8List> updatedAvatars = Map.from(state.peerAvatars);
        if (!message.isFromMe && message.senderAvatarBytes != null) {
          updatedAvatars[message.senderUUID] = message.senderAvatarBytes!;
        }
        // Track peer public key from message
        Map<String, String> updatedPubKeys = Map.from(state.peerPublicKeys);
        if (!message.isFromMe && message.senderPublicKeyHex != null) {
          updatedPubKeys[message.senderUUID] = message.senderPublicKeyHex!;
        }
        // Also pull from client's map (from handshakes)
        final clientPubKeys = _client?.peerPublicKeys ?? {};
        for (final e in clientPubKeys.entries) {
          updatedPubKeys.putIfAbsent(e.key, () => e.value);
        }
        // If a message with this id already exists (e.g. isSending echo being
        // updated to isSending: false), replace it instead of appending.
        final existingIdx = state.messages.indexWhere((m) => m.id == message.id);
        final List<ChatMessage> updated;
        if (existingIdx >= 0) {
          updated = List<ChatMessage>.from(state.messages);
          updated[existingIdx] = message;
        } else {
          updated = List<ChatMessage>.from(state.messages)..add(message);
        }
        emit(state.copyWith(
          messages: updated,
          peerAvatars: updatedAvatars,
          peerPublicKeys: updatedPubKeys,
        ));

      case SgtpPeerJoined(:final peerUUID, :final ed25519PubHex):
        final nick = state.nicknames[ed25519PubHex];
        final updatedNick = Map<String, String>.from(state.peerNicknames);
        if (nick != null) updatedNick[peerUUID] = nick;
        final displayName = nick ?? peerUUID.substring(0, 8);
        final systemMsg = _createSystemMessage('👤 $displayName joined the chat');
        final updatedMessages = List<ChatMessage>.from(state.messages)..add(systemMsg);
        final updatedHistory = Map<String, String>.from(state.peerNicknamesHistory);
        if (nick != null) updatedHistory[peerUUID] = nick;
        final updatedPubKeys = Map<String, String>.from(state.peerPublicKeys);
        updatedPubKeys[peerUUID] = ed25519PubHex;
        if (!state.peerUUIDs.contains(peerUUID)) {
          emit(state.copyWith(
            messages: updatedMessages, peerUUIDs: [...state.peerUUIDs, peerUUID],
            peerNicknames: updatedNick, peerNicknamesHistory: updatedHistory,
            peerPublicKeys: updatedPubKeys,
          ));
        } else {
          emit(state.copyWith(
            messages: updatedMessages,
            peerNicknames: updatedNick, peerNicknamesHistory: updatedHistory,
            peerPublicKeys: updatedPubKeys,
          ));
        }

      case SgtpPeerLeft(:final peerUUID):
        final nick = state.peerNicknames[peerUUID] ?? state.peerNicknamesHistory[peerUUID];
        final displayName = nick ?? peerUUID.substring(0, 8);
        final systemMsg = _createSystemMessage('👤 $displayName left the chat');
        final updatedMessages = List<ChatMessage>.from(state.messages)..add(systemMsg);
        final updatedNicknames = Map<String, String>.from(state.peerNicknames)..remove(peerUUID);
        final updatedHistory = Map<String, String>.from(state.peerNicknamesHistory);
        if (nick != null) updatedHistory[peerUUID] = nick;
        emit(state.copyWith(
          messages: updatedMessages,
          peerUUIDs: state.peerUUIDs.where((id) => id != peerUUID).toList(),
          peerNicknames: updatedNicknames, peerNicknamesHistory: updatedHistory,
        ));

      case SgtpError(:final error):
        emit(state.copyWith(status: ChatStatus.error, errorMessage: error));

      case SgtpDisconnected():
        emit(state.copyWith(status: ChatStatus.disconnected));

      case SgtpChatMetadataReceived(:final chatName, :final avatarBytes, :final senderUUID):
        debugPrint('[ChatBloc] Got metadata from $senderUUID: "$chatName"');
        emit(state.copyWith(chatName: chatName, chatAvatarBytes: avatarBytes));
        final roomUUID = state.roomUUID.isNotEmpty
            ? state.roomUUID
            : (_client?.roomUUIDHex ?? '');
        _saveMetadata(roomUUID, chatName, avatarBytes);

      case SgtpMediaProgress(:final echoId, :final progress):
        // Update sendProgress on the in-flight outgoing message
        final updatedMsgs = state.messages.map<ChatMessage>((m) {
          if (m.id == echoId) return m.copyWith(sendProgress: progress);
          return m;
        }).toList();
        emit(state.copyWith(messages: updatedMsgs));

      case SgtpReactionReceived(:final messageId, :final emoji, :final senderUUID, :final add):
        final current     = Map<String, Map<String, Set<String>>>.from(state.reactions);
        final msgReactions = Map<String, Set<String>>.from(current[messageId] ?? {});
        final who          = Set<String>.from(msgReactions[emoji] ?? {});
        if (add) { who.add(senderUUID); } else { who.remove(senderUUID); }
        if (who.isEmpty) { msgReactions.remove(emoji); } else { msgReactions[emoji] = who; }
        current[messageId] = msgReactions;
        final updatedMsgs = state.messages.map<ChatMessage>((m) {
          if (m.id == messageId) return m.copyWith(reactions: msgReactions);
          return m;
        }).toList();
        emit(state.copyWith(reactions: current, messages: updatedMsgs));

      case SgtpMessageReadReceived(:final readMessageId, :final readerUUID):
        final current = Map<String, Set<String>>.from(state.readReceipts);
        final readers = Set<String>.from(current[readMessageId] ?? {});
        readers.add(readerUUID);
        current[readMessageId] = readers;
        // Also update the message in the list so readBy set is current
        final updatedMsgs = state.messages.map<ChatMessage>((m) {
          if (m.id == readMessageId) {
            return m.copyWith(readBy: Set<String>.from(m.readBy)..add(readerUUID));
          }
          return m;
        }).toList();
        emit(state.copyWith(readReceipts: current, messages: updatedMsgs));
    }
  }

  @override
  Future<void> close() async {
    await _eventSub?.cancel();
    await _client?.close();
    return super.close();
  }
}
