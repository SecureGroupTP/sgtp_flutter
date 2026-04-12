import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:sgtp_flutter/core/app_log.dart';
import 'package:sgtp_flutter/core/video_note_pipeline.dart';

import 'package:sgtp_flutter/features/messaging/application/models/messaging_models.dart';
import 'package:sgtp_flutter/features/messaging/application/viewmodels/chat/chat_event.dart';
import 'package:sgtp_flutter/features/messaging/application/viewmodels/chat/chat_state.dart';
import 'package:sgtp_flutter/features/messaging/domain/repositories/chat_storage_gateway.dart';
import 'package:sgtp_flutter/features/messaging/domain/repositories/i_sgtp_session.dart';

class ChatBloc extends Bloc<ChatEvent, ChatState> {
  final _log = AppLog('ChatBloc');
  final _logVideo = AppLog('VideoNote');
  ISgtpSession? _client;
  StreamSubscription<SgtpEvent>? _eventSub;
  late final SgtpSessionFactory _sessionFactory;
  final ChatMetadataStore _metaRepo;
  DateTime? _lastActivityPersistAt;
  static const int _historyBatchSize = 100;
  String _activeServerAddress = '';
  int _persistedHistoryLoaded = 0;

  // Keep last config for reconnect
  ChatConnect? _lastConnectEvent;

  /// Incremented on every (re)connect. Events emitted by a previous session
  /// carry the old session ID and are silently ignored, which prevents stale
  /// SgtpPeerJoined / SgtpPeerLeft events from polluting peerUUIDs after a
  /// reconnect.
  int _sessionId = 0;
  Map<String, Uint8List> _contactAvatarsByPub = const {};

  ChatBloc({
    required String accountId,
    required ChatStorageGateway storageGateway,
    required SgtpSessionFactory sessionFactory,
  })  : _metaRepo = storageGateway.metadataForAccount(accountId),
        super(const ChatState()) {
    _sessionFactory = sessionFactory;
    on<ChatConnect>(_onConnect);
    on<ChatOpenOffline>(_onOpenOffline);
    on<ChatReconnect>(_onReconnect);
    on<ChatProbeConnection>(_onProbeConnection);
    on<ChatSendMessage>(_onSendMessage);
    on<ChatSendImage>(_onSendImage);
    on<ChatSendVideo>(_onSendVideo);
    on<ChatSendVoice>(_onSendVoice);
    on<ChatSendVideoNote>(_onSendVideoNote);
    on<ChatSendVideoNoteFile>(_onSendVideoNoteFile);
    on<ChatSendMessageRead>(_onSendMessageRead);
    on<ChatLoadOlderHistory>(_onLoadOlderHistory);
    on<ChatDisconnect>(_onDisconnect);
    on<ChatUpdateMetadata>(_onUpdateMetadata);
    on<ChatSetUserAvatar>(_onSetUserAvatar);
    on<ChatSetReply>(_onSetReply);
    on<ChatClearReply>(_onClearReply);
    on<ChatToggleReaction>(_onToggleReaction);
    on<ChatUpdateNicknames>(_onUpdateNicknames);
    on<ChatUpdateContactAvatars>(_onUpdateContactAvatars);
    on<ChatUpdateWhitelist>((event, emit) {
      _client?.updateWhitelist(event.whitelist);
    });
    on<ChatInternalSgtpEvent>(_onSgtpEvent);
  }

  Future<void> _onConnect(ChatConnect event, Emitter<ChatState> emit) async {
    _lastConnectEvent = event;
    await _doConnect(event, emit);
  }

  Future<void> _onOpenOffline(
      ChatOpenOffline event, Emitter<ChatState> emit) async {
    final oldSub = _eventSub;
    final oldClient = _client;
    _eventSub = null;
    _client = null;
    await oldSub?.cancel();
    await oldClient?.close();

    // Keep the connect payload so "Connect" can bring this room online later.
    final connectEvent = ChatConnect(event.config, nicknames: event.nicknames);
    _lastConnectEvent = connectEvent;

    _activeServerAddress = event.config.serverAddr.trim();
    _persistedHistoryLoaded = 0;

    final roomUUIDHex = event.config.roomUUID
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    final pubHex = event.config.myPublicKey
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();

    // Prefer persisted metadata for title/avatar in offline preview.
    String chatName = event.config.chatName;
    Uint8List? chatAvatar = event.config.chatAvatarBytes;
    var isDirectChat = false;
    try {
      final saved = await _metaRepo.loadChat(
        roomUUIDHex,
        serverAddress: _activeServerAddress,
      );
      if (saved != null) {
        chatName = saved.name;
        chatAvatar = saved.avatarBytes;
        isDirectChat = saved.isDirectMessage;
        _log.info('[ChatBloc] OpenOffline room={room} direct={direct} name="{name}" avatar={avatarSize}B', parameters: {'room': roomUUIDHex, 'direct': isDirectChat, 'name': chatName, 'avatarSize': chatAvatar?.length ?? 0});
      }
    } catch (_) {}

    final sessionId = ++_sessionId;
    final client = _sessionFactory(event.config.copyWithMeta(
      name: chatName,
      avatar: chatAvatar,
    ));
    if (state.userAvatarBytes != null) {
      client.setUserAvatar(state.userAvatarBytes);
    }
    _client = client;

    _eventSub = client.events.listen(
      (sgtpEvent) =>
          add(ChatInternalSgtpEvent(sgtpEvent, sessionId: sessionId)),
      onError: (e) => add(ChatInternalSgtpEvent(SgtpError(error: e.toString()),
          sessionId: sessionId)),
    );

    emit(state.copyWith(
      status: ChatStatus.disconnected,
      messages: [],
      peerUUIDs: [],
      peerNicknames: {},
      peerPublicKeys: {},
      peerAvatars: {},
      readReceipts: {},
      hasMoreHistory: true,
      isLoadingHistory: false,
      isMaster: false,
      roomUUID: roomUUIDHex,
      myPublicKeyHex: pubHex,
      nicknames: event.nicknames,
      chatName: chatName,
      chatAvatarBytes: chatAvatar,
      isDirectChat: isDirectChat,
      clearError: true,
    ));

    final initial = await client.replayPersistedHistoryBatch(
      offsetFromEnd: _persistedHistoryLoaded,
      limit: _historyBatchSize,
    );
    _persistedHistoryLoaded += initial.loaded;
    if (!isClosed) {
      emit(state.copyWith(
        hasMoreHistory: _persistedHistoryLoaded < initial.total,
      ));
    }
  }

  Future<void> _onReconnect(
      ChatReconnect event, Emitter<ChatState> emit) async {
    final last = _lastConnectEvent;
    if (last == null) return;
    await _doConnect(last, emit);
  }

  Future<void> _onProbeConnection(
      ChatProbeConnection event, Emitter<ChatState> emit) async {
    await _client?.probeConnection();
  }

  Future<void> _doConnect(ChatConnect event, Emitter<ChatState> emit) async {
    final oldSub = _eventSub;
    final oldClient = _client;
    _eventSub = null;
    _client = null;
    await oldSub?.cancel();
    await oldClient?.close();

    // Load saved metadata from disk BEFORE creating client,
    // so we pass correct name/avatar into SgtpClient from the start.
    _activeServerAddress = event.config.serverAddr.trim();
    _persistedHistoryLoaded = 0;

    String chatName = event.config.chatName;
    Uint8List? chatAvatar = event.config.chatAvatarBytes;
    var isDirectChat = false;

    final roomUUIDHex = event.config.roomUUID
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    final isRealRoom = !event.config.roomUUID.every((b) => b == 0);

    if (isRealRoom) {
      try {
        final saved = await _metaRepo.loadChat(
          roomUUIDHex,
          serverAddress: _activeServerAddress,
        );
        if (saved != null) {
          chatName = saved.name;
          chatAvatar = saved.avatarBytes;
          isDirectChat = saved.isDirectMessage;
          if (saved.serverAddress.trim().isNotEmpty) {
            _activeServerAddress = saved.serverAddress.trim();
          }
          _log.info('[ChatBloc] Pre-loaded metadata room={room} direct={direct} name="{name}" avatar={avatarSize}B', parameters: {'room': roomUUIDHex, 'direct': isDirectChat, 'name': saved.name, 'avatarSize': saved.avatarBytes?.length ?? 0});
        }
      } catch (_) {}
    }

    _eventSub = null;
    _client = null;

    // Stamp this session so any stale in-queue events from the old connection
    // (already added to the BLoC queue before cancel()) can be discarded.
    final sessionId = ++_sessionId;

    // Build config with resolved metadata so the client broadcasts correct name
    final resolvedConfig = event.config.copyWithMeta(
      name: chatName,
      avatar: chatAvatar,
    );

    final client = _sessionFactory(resolvedConfig);
    // Pass user avatar to the client so it attaches it to outgoing messages
    if (state.userAvatarBytes != null) {
      client.setUserAvatar(state.userAvatarBytes);
    }
    _client = client;

    final pubHex = event.config.myPublicKey
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();

    emit(state.copyWith(
      status: ChatStatus.connecting,
      // Preserve existing messages and reactions — they live in RAM until app close.
      // Only clear messages on a *fresh* connect (different room UUID).
      messages: (isRealRoom &&
              state.roomUUID.isNotEmpty &&
              state.roomUUID != roomUUIDHex)
          ? []
          : state.messages,
      peerUUIDs: [],
      peerNicknames: {},
      peerPublicKeys: {},
      peerAvatars: {},
      readReceipts: {},
      hasMoreHistory: true,
      isLoadingHistory: false,
      isMaster: false,
      myPublicKeyHex: pubHex,
      nicknames: event.nicknames,
      chatName: chatName,
      chatAvatarBytes: chatAvatar,
      isDirectChat: isDirectChat,
      clearError: true,
    ));

    _eventSub = client.events.listen(
      (sgtpEvent) =>
          add(ChatInternalSgtpEvent(sgtpEvent, sessionId: sessionId)),
      onError: (e) => add(ChatInternalSgtpEvent(SgtpError(error: e.toString()),
          sessionId: sessionId)),
    );

    final initial = await client.replayPersistedHistoryBatch(
      offsetFromEnd: _persistedHistoryLoaded,
      limit: _historyBatchSize,
    );
    _persistedHistoryLoaded += initial.loaded;
    if (!isClosed) {
      emit(state.copyWith(
        hasMoreHistory: _persistedHistoryLoaded < initial.total,
      ));
    }

    await client.connect();
  }

  Future<void> _onSendMessage(
      ChatSendMessage event, Emitter<ChatState> emit) async {
    if (_client == null || state.status != ChatStatus.ready) return;
    await _client!.sendMessage(
      event.text,
      replyToId: event.replyToId,
      replyToContent: event.replyToContent,
      replyToSender: event.replyToSender,
    );
    await _touchChatActivity();
    // Clear reply after send
    if (event.replyToId != null) emit(state.copyWith(clearReply: true));
  }

  void _onUpdateNicknames(ChatUpdateNicknames event, Emitter<ChatState> emit) {
    // Rebuild peerNicknames from current peerPublicKeys + new nickname map.
    // This ensures peers who joined before the contact was added get their
    // nickname shown immediately without requiring a reconnect.
    final newNicknames = Map<String, String>.from(event.nicknames);
    final updatedPeerNicks = Map<String, String>.from(state.peerNicknames);
    final updatedHistory = Map<String, String>.from(state.peerNicknamesHistory);

    for (final entry in state.peerPublicKeys.entries) {
      final sessionUUID = entry.key;
      final pubHex = entry.value;
      final nick = newNicknames[pubHex];
      if (nick != null) {
        updatedPeerNicks[sessionUUID] = nick;
        updatedHistory[sessionUUID] = nick;
      }
    }
    final directDisplay = _directChatDisplayFor(
      state.peerPublicKeys,
      nicknames: newNicknames,
    );
    final isDirect = state.isDirectChat;
    emit(state.copyWith(
      nicknames: newNicknames,
      peerNicknames: updatedPeerNicks,
      peerNicknamesHistory: updatedHistory,
      chatName:
          isDirect && directDisplay != null ? directDisplay.name : state.chatName,
      chatAvatarBytes: isDirect && directDisplay != null
          ? directDisplay.avatar
          : state.chatAvatarBytes,
      clearAvatar:
          isDirect && directDisplay != null && directDisplay.avatar == null,
    ));
  }

  void _onUpdateContactAvatars(
      ChatUpdateContactAvatars event, Emitter<ChatState> emit) {
    _contactAvatarsByPub = Map<String, Uint8List>.from(event.avatarsByPubkey);
    final directDisplay = _directChatDisplayFor(state.peerPublicKeys);
    final isDirect = state.isDirectChat;
    emit(state.copyWith(
      peerAvatars: _peerAvatarsFor(state.peerPublicKeys),
      chatName:
          isDirect && directDisplay != null ? directDisplay.name : state.chatName,
      chatAvatarBytes: isDirect && directDisplay != null
          ? directDisplay.avatar
          : state.chatAvatarBytes,
      clearAvatar:
          isDirect && directDisplay != null && directDisplay.avatar == null,
    ));
  }

  Map<String, Uint8List> _peerAvatarsFor(Map<String, String> peerPublicKeys) {
    final out = <String, Uint8List>{};
    for (final entry in peerPublicKeys.entries) {
      final avatar = _contactAvatarsByPub[entry.value];
      if (avatar != null && avatar.isNotEmpty) {
        out[entry.key] = avatar;
      }
    }
    return out;
  }

  ({String name, Uint8List? avatar})? _directChatDisplayFor(
    Map<String, String> peerPublicKeys, {
    Map<String, String>? nicknames,
  }) {
    if (peerPublicKeys.length != 1) return null;
    final pubHex = peerPublicKeys.values.first;
    final sourceNicknames = nicknames ?? state.nicknames;
    final rawName = sourceNicknames[pubHex]?.trim() ?? '';
    final fallbackName =
        pubHex.length >= 8 ? 'peer_${pubHex.substring(0, 8)}' : 'Direct chat';
    final name = rawName.isNotEmpty ? rawName : fallbackName;
    final avatar = _contactAvatarsByPub[pubHex];
    return (name: name, avatar: avatar);
  }

  void _onSetReply(ChatSetReply event, Emitter<ChatState> emit) {
    emit(state.copyWith(replyToMessage: event.message));
  }

  void _onClearReply(ChatClearReply event, Emitter<ChatState> emit) {
    emit(state.copyWith(clearReply: true));
  }

  void _onToggleReaction(ChatToggleReaction event, Emitter<ChatState> emit) {
    final current = Map<String, Map<String, Set<String>>>.from(state.reactions);
    final msgReactions =
        Map<String, Set<String>>.from(current[event.messageId] ?? {});
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

  Future<void> _onSendImage(
      ChatSendImage event, Emitter<ChatState> emit) async {
    if (_client == null || state.status != ChatStatus.ready) return;
    await _client!.sendImage(event.bytes, event.name, event.mime);
    await _touchChatActivity();
  }

  Future<void> _onSendVideo(
      ChatSendVideo event, Emitter<ChatState> emit) async {
    if (_client == null || state.status != ChatStatus.ready) return;
    await _client!.sendVideo(event.xFile, event.name, event.mime);
    await _touchChatActivity();
  }

  Future<void> _onSendVoice(
      ChatSendVoice event, Emitter<ChatState> emit) async {
    if (_client == null || state.status != ChatStatus.ready) return;
    await _client!.sendVoice(event.bytes, event.mime);
    await _touchChatActivity();
  }

  Future<void> _onSendVideoNote(
      ChatSendVideoNote event, Emitter<ChatState> emit) async {
    if (_client == null || state.status != ChatStatus.ready) return;
    await _client!.sendVideoNote(event.bytes, event.mime);
    await _touchChatActivity();
  }

  Future<void> _onSendVideoNoteFile(
      ChatSendVideoNoteFile event, Emitter<ChatState> emit) async {
    if (_client == null || state.status != ChatStatus.ready) return;
    try {
      _logVideo.info('[ChatBloc] Video note send start: ${event.xFile.path}');
      final prepared = event.metadata != null
          ? PreparedVideoNote(
              xFile: event.xFile,
              mime: event.mime,
              metadata: event.metadata!,
            )
          : await VideoNotePipeline.prepare(sourceFile: event.xFile);
      _logVideo.info('[ChatBloc] Video note prepared: mime=${prepared.mime}, '
          '${prepared.metadata.width}x${prepared.metadata.height}, '
          'duration=${prepared.metadata.durationMs}ms');
      await _client!.sendVideoNoteFromXFile(
        prepared.xFile,
        prepared.mime,
        metadata: prepared.metadata,
      );
      _logVideo.info('[ChatBloc] Video note send handed to client');
      await _touchChatActivity();
    } catch (e) {
      _logVideo.error('[ChatBloc] Video note send failed: $e');
      rethrow;
    }
  }

  Future<void> _onSendMessageRead(
      ChatSendMessageRead event, Emitter<ChatState> emit) async {
    if (_client == null || state.status != ChatStatus.ready) return;
    await _client!.sendMessageRead(event.messageId);
    await _touchChatActivity();
  }

  Future<void> _onLoadOlderHistory(
      ChatLoadOlderHistory event, Emitter<ChatState> emit) async {
    final client = _client;
    if (client == null) return;
    if (state.isLoadingHistory || !state.hasMoreHistory) return;

    emit(state.copyWith(isLoadingHistory: true));
    try {
      final batch = await client.replayPersistedHistoryBatch(
        offsetFromEnd: _persistedHistoryLoaded,
        limit: _historyBatchSize,
      );
      _persistedHistoryLoaded += batch.loaded;
      emit(state.copyWith(
        isLoadingHistory: false,
        hasMoreHistory: _persistedHistoryLoaded < batch.total,
      ));
    } catch (_) {
      emit(state.copyWith(isLoadingHistory: false));
    }
  }

  Future<void> _onDisconnect(
      ChatDisconnect event, Emitter<ChatState> emit) async {
    final client = _client;
    _client =
        null; // null first so SgtpDisconnected handler won't auto-reconnect
    await client?.disconnect();
    await _eventSub?.cancel();
    _eventSub = null;
    emit(state.copyWith(status: ChatStatus.disconnected));
  }

  Future<void> _onUpdateMetadata(
      ChatUpdateMetadata event, Emitter<ChatState> emit) async {
    emit(state.copyWith(
        chatName: event.name, chatAvatarBytes: event.avatarBytes));
    await _client?.sendChatMeta(event.name, event.avatarBytes);
    final roomUUID = state.roomUUID.isNotEmpty
        ? state.roomUUID
        : (_client?.roomUUIDHex ?? '');
    await _saveMetadata(roomUUID, event.name, event.avatarBytes);
  }

  Future<void> _onSetUserAvatar(
      ChatSetUserAvatar event, Emitter<ChatState> emit) async {
    emit(state.copyWith(userAvatarBytes: event.avatarBytes));
    _client?.setUserAvatar(event.avatarBytes);
  }

  Future<void> _saveMetadata(
      String roomUUID, String name, Uint8List? avatar) async {
    if (roomUUID.isEmpty) return;
    try {
      final now = DateTime.now();
      final existing = await _metaRepo.loadChat(
        roomUUID,
        serverAddress: _activeServerAddress,
      );
      final meta = ChatMetadata(
        uuid: roomUUID,
        name: name,
        serverAddress: _activeServerAddress,
        avatarBytes: avatar,
        isDirectMessage: existing?.isDirectMessage ?? state.isDirectChat,
        createdAt: existing?.createdAt ?? now,
        updatedAt: now,
      );
      await _metaRepo.saveChat(meta);
      _log.info('[ChatBloc] Saved metadata for {room}: "{name}"', parameters: {'room': roomUUID, 'name': name});
    } catch (e) {
      _log.info('[ChatBloc] Failed to save metadata: {error}', parameters: {'error': e});
    }
  }

  Future<void> _touchChatActivity() async {
    final roomUUID = state.roomUUID.isNotEmpty
        ? state.roomUUID
        : (_client?.roomUUIDHex ?? '');
    if (roomUUID.isEmpty) return;

    final now = DateTime.now();
    if (_lastActivityPersistAt != null &&
        now.difference(_lastActivityPersistAt!) < const Duration(seconds: 15)) {
      return;
    }

    try {
      final existing = await _metaRepo.loadChat(
        roomUUID,
        serverAddress: _activeServerAddress,
      );
      final metadata = ChatMetadata(
        uuid: roomUUID,
        name: existing?.name ?? state.chatName,
        serverAddress: _activeServerAddress,
        avatarBytes: existing?.avatarBytes ?? state.chatAvatarBytes,
        isDirectMessage: existing?.isDirectMessage ?? state.isDirectChat,
        createdAt: existing?.createdAt ?? now,
        updatedAt: now,
        windowWidth: existing?.windowWidth,
        windowHeight: existing?.windowHeight,
      );
      await _metaRepo.saveChat(metadata);
      _lastActivityPersistAt = now;
    } catch (e) {
      _log.info('[ChatBloc] Failed to persist chat activity: {error}', parameters: {'error': e});
    }
  }

  ChatMessage _createSystemMessage(String content) => ChatMessage(
        id: DateTime.now().millisecondsSinceEpoch.toString().padLeft(16, '0'),
        senderUUID: 'system',
        content: content,
        type: MessageType.system,
        receivedAt: DateTime.now(),
        isFromHistory: false,
        isFromMe: false,
      );

  void _onSgtpEvent(ChatInternalSgtpEvent event, Emitter<ChatState> emit) {
    // Discard events from a previous (now-cancelled) connection session.
    if (event.sessionId != _sessionId) return;

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
          // Use a Set to ensure no duplicates survive across reconnects
          peerUUIDs: (_client?.peerUUIDs ?? []).toSet().toList(),
        ));
        _saveMetadata(roomUUIDHex, state.chatName, state.chatAvatarBytes);

      case SgtpMessageReceived(:final message):
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
        final existingIdx =
            state.messages.indexWhere((m) => m.id == message.id);
        final List<ChatMessage> updated;
        if (existingIdx >= 0) {
          updated = List<ChatMessage>.from(state.messages);
          updated[existingIdx] = message;
        } else {
          updated = List<ChatMessage>.from(state.messages)..add(message);
          if (message.isFromHistory) {
            updated.sort((a, b) => a.receivedAt.compareTo(b.receivedAt));
          }
        }
        emit(state.copyWith(
          messages: updated,
          peerPublicKeys: updatedPubKeys,
          peerAvatars: _peerAvatarsFor(updatedPubKeys),
        ));
        _touchChatActivity();

      case SgtpPeerJoined(:final peerUUID, :final ed25519PubHex):
        final nick = state.nicknames[ed25519PubHex];
        final updatedNick = Map<String, String>.from(state.peerNicknames);
        if (nick != null) updatedNick[peerUUID] = nick;
        final displayName = nick ?? peerUUID.substring(0, 8);
        final systemMsg = _createSystemMessage('$displayName joined the chat');
        final updatedMessages = List<ChatMessage>.from(state.messages)
          ..add(systemMsg);
        final updatedHistory =
            Map<String, String>.from(state.peerNicknamesHistory);
        if (nick != null) updatedHistory[peerUUID] = nick;
        final updatedPubKeys = Map<String, String>.from(state.peerPublicKeys);
        updatedPubKeys[peerUUID] = ed25519PubHex;
        final directDisplay = _directChatDisplayFor(updatedPubKeys);
        final isDirect = state.isDirectChat;
        final nextChatName =
            isDirect && directDisplay != null ? directDisplay.name : state.chatName;
        final nextChatAvatar =
            isDirect && directDisplay != null
                ? directDisplay.avatar
                : state.chatAvatarBytes;
        if (!state.peerUUIDs.contains(peerUUID)) {
          emit(state.copyWith(
            messages: updatedMessages,
            peerUUIDs: [...state.peerUUIDs, peerUUID],
            peerNicknames: updatedNick,
            peerNicknamesHistory: updatedHistory,
            peerPublicKeys: updatedPubKeys,
            peerAvatars: _peerAvatarsFor(updatedPubKeys),
            chatName: nextChatName,
            chatAvatarBytes: nextChatAvatar,
            clearAvatar:
                isDirect && directDisplay != null && nextChatAvatar == null,
          ));
        } else {
          emit(state.copyWith(
            messages: updatedMessages,
            peerNicknames: updatedNick,
            peerNicknamesHistory: updatedHistory,
            peerPublicKeys: updatedPubKeys,
            peerAvatars: _peerAvatarsFor(updatedPubKeys),
            chatName: nextChatName,
            chatAvatarBytes: nextChatAvatar,
            clearAvatar:
                isDirect && directDisplay != null && nextChatAvatar == null,
          ));
        }
        final roomUUID = state.roomUUID.isNotEmpty
            ? state.roomUUID
            : (_client?.roomUUIDHex ?? '');
        _saveMetadata(roomUUID, nextChatName, nextChatAvatar);

      case SgtpPeerLeft(:final peerUUID):
        final nick = state.peerNicknames[peerUUID] ??
            state.peerNicknamesHistory[peerUUID];
        final displayName = nick ?? peerUUID.substring(0, 8);
        final systemMsg = _createSystemMessage('$displayName left the chat');
        final updatedMessages = List<ChatMessage>.from(state.messages)
          ..add(systemMsg);
        final updatedNicknames = Map<String, String>.from(state.peerNicknames)
          ..remove(peerUUID);
        final updatedHistory =
            Map<String, String>.from(state.peerNicknamesHistory);
        if (nick != null) updatedHistory[peerUUID] = nick;
        final updatedPubKeys = Map<String, String>.from(state.peerPublicKeys)
          ..remove(peerUUID);
        final directDisplay = _directChatDisplayFor(updatedPubKeys);
        final isDirect = state.isDirectChat;
        emit(state.copyWith(
          messages: updatedMessages,
          peerUUIDs: state.peerUUIDs.where((id) => id != peerUUID).toList(),
          peerNicknames: updatedNicknames,
          peerNicknamesHistory: updatedHistory,
          peerPublicKeys: updatedPubKeys,
          peerAvatars: _peerAvatarsFor(updatedPubKeys),
          chatName:
              isDirect && directDisplay != null ? directDisplay.name : state.chatName,
          chatAvatarBytes: isDirect && directDisplay != null
              ? directDisplay.avatar
              : state.chatAvatarBytes,
          clearAvatar:
              isDirect && directDisplay != null && directDisplay.avatar == null,
        ));

      case SgtpError(:final error):
        emit(state.copyWith(status: ChatStatus.error, errorMessage: error));

      case SgtpDisconnected():
        emit(state.copyWith(status: ChatStatus.disconnected));
        // Auto-reconnect on unexpected server disconnect (e.g. NAT timeout,
        // server restart). We wait 3 s to avoid a tight reconnect loop.
        // If the user explicitly disconnected via ChatDisconnect, _lastConnectEvent
        // is still set but _client is null — we guard against that.
        if (_lastConnectEvent != null && _client != null) {
          Future.delayed(const Duration(seconds: 3), () {
            if (!isClosed && state.status == ChatStatus.disconnected) {
              _log.info('[ChatBloc] Auto-reconnecting after unexpected disconnect');
              add(const ChatReconnect());
            }
          });
        }

      case SgtpChatMetadataReceived(
          :final chatName,
          :final avatarBytes,
          :final senderUUID
        ):
        final mergedPubKeys = Map<String, String>.from(state.peerPublicKeys)
          ..addAll(_client?.peerPublicKeys ?? const {});
        final directDisplay = _directChatDisplayFor(mergedPubKeys);
        final isDirect = state.isDirectChat;
        final effectiveName =
            isDirect && directDisplay != null ? directDisplay.name : chatName;
        final effectiveAvatar =
            isDirect && directDisplay != null ? directDisplay.avatar : avatarBytes;
        _log.info('[ChatBloc] Got metadata from {sender}: "{chatName}" -> "{effectiveName}"', parameters: {'sender': senderUUID, 'chatName': chatName, 'effectiveName': effectiveName});
        emit(state.copyWith(
          chatName: effectiveName,
          chatAvatarBytes: effectiveAvatar,
          clearAvatar:
              isDirect && directDisplay != null && effectiveAvatar == null,
          peerPublicKeys: mergedPubKeys,
          peerAvatars: _peerAvatarsFor(mergedPubKeys),
        ));
        final roomUUID = state.roomUUID.isNotEmpty
            ? state.roomUUID
            : (_client?.roomUUIDHex ?? '');
        _saveMetadata(roomUUID, effectiveName, effectiveAvatar);

      case SgtpMediaProgress(:final echoId, :final progress):
        // Update sendProgress on the in-flight outgoing message.
        // Ignore tiny deltas to avoid excessive full-list rebuilds.
        var changed = false;
        final updatedMsgs = state.messages.map<ChatMessage>((m) {
          if (m.id != echoId) return m;
          final next = progress.clamp(0.0, 1.0);
          final delta = (next - m.sendProgress).abs();
          if (delta < 0.01 && next < 1.0) return m;
          changed = true;
          return m.copyWith(sendProgress: next);
        }).toList();
        if (changed) {
          emit(state.copyWith(messages: updatedMsgs));
        }

      case SgtpReactionReceived(
          :final messageId,
          :final emoji,
          :final senderUUID,
          :final add
        ):
        final current =
            Map<String, Map<String, Set<String>>>.from(state.reactions);
        final msgReactions =
            Map<String, Set<String>>.from(current[messageId] ?? {});
        final who = Set<String>.from(msgReactions[emoji] ?? {});
        if (add) {
          who.add(senderUUID);
        } else {
          who.remove(senderUUID);
        }
        if (who.isEmpty) {
          msgReactions.remove(emoji);
        } else {
          msgReactions[emoji] = who;
        }
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
            return m.copyWith(
                readBy: Set<String>.from(m.readBy)..add(readerUUID));
          }
          return m;
        }).toList();
        emit(state.copyWith(readReceipts: current, messages: updatedMsgs));
        _touchChatActivity();
    }
  }

  @override
  Future<void> close() async {
    await _eventSub?.cancel();
    await _client?.close();
    return super.close();
  }
}
