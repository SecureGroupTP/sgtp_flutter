import 'dart:typed_data';
import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:sgtp_flutter/core/app_log.dart';
import 'package:sgtp_flutter/features/messaging/application/models/messaging_models.dart';
import 'package:sgtp_flutter/core/uuid_v7.dart';
import 'package:sgtp_flutter/features/messaging/domain/repositories/chat_storage_gateway.dart';

part 'chat_list_event.dart';
part 'chat_list_state.dart';

/// BLoC для управления списком сохраненных чатов и их метаданными
class ChatListBloc extends Bloc<ChatListEvent, ChatListState> {
  final _log = AppLog('ChatListBloc');
  final ChatMetadataStore _repository;

  ChatListBloc({required ChatMetadataStore repository})
      : _repository = repository,
        super(const ChatListState()) {
    on<ChatListLoadChats>(_onLoadChats);
    on<ChatListCreateChat>(_onCreateChat);
    on<ChatListUpdateChat>(_onUpdateChat);
    on<ChatListDeleteChat>(_onDeleteChat);
    on<ChatListSetMuted>(_onSetMuted);
    on<ChatListRefresh>(_onRefresh);
    on<ChatListSelectChat>(_onSelectChat);
    on<ChatListUpdateWindowSize>(_onUpdateWindowSize);
    on<ChatListMetadataReceived>(_onMetadataReceived);
  }

  /// Load all chats from disk
  Future<void> _onLoadChats(
    ChatListLoadChats event,
    Emitter<ChatListState> emit,
  ) async {
    emit(state.copyWith(status: ChatListStatus.loading));

    try {
      final chats = await _repository.loadAllChats();
      _log.info('[ChatListBloc] Loaded {count} chats', parameters: {'count': chats.length});

      emit(state.copyWith(
        status: ChatListStatus.loaded,
        chats: chats,
      ));
    } catch (e) {
      _log.error('[ChatListBloc] Error loading chats: {error}', parameters: {'error': e});
      emit(state.copyWith(
        status: ChatListStatus.error,
        errorMessage: 'Failed to load chats: $e',
      ));
    }
  }

  /// Create a new chat
  Future<void> _onCreateChat(
    ChatListCreateChat event,
    Emitter<ChatListState> emit,
  ) async {
    try {
      final uuid = uuidBytesToHex(generateUUIDv7());
      final now = DateTime.now();

      final newChat = ChatMetadata(
        uuid: uuid,
        name: event.name,
        serverAddress: '',
        avatarBytes: event.avatarBytes,
        createdAt: now,
        updatedAt: now,
      );

      await _repository.saveChat(newChat);
      _log.info('[ChatListBloc] Created chat: {uuid}', parameters: {'uuid': uuid});

      final updatedChats = [newChat, ...state.chats];
      emit(state.copyWith(
        status: ChatListStatus.loaded,
        chats: updatedChats,
        selectedChat: newChat,
      ));
    } catch (e) {
      _log.error('[ChatListBloc] Error creating chat: {error}', parameters: {'error': e});
      emit(state.copyWith(
        status: ChatListStatus.error,
        errorMessage: 'Failed to create chat: $e',
      ));
    }
  }

  /// Update existing chat
  Future<void> _onUpdateChat(
    ChatListUpdateChat event,
    Emitter<ChatListState> emit,
  ) async {
    try {
      // Find the chat to update
      final chatToUpdate = state.chats.firstWhere(
        (c) => c.uuid == event.uuid,
        orElse: () => throw Exception('Chat not found'),
      );

      // Create updated version
      final updated = chatToUpdate.copyWith(
        name: event.newName,
        avatarBytes: event.newAvatarBytes,
        updatedAt: DateTime.now(),
      );

      await _repository.updateChat(updated);
      _log.info('[ChatListBloc] Updated chat: {uuid}', parameters: {'uuid': event.uuid});

      // Update in list
      final updatedChats =
          state.chats.map((c) => c.uuid == event.uuid ? updated : c).toList();

      // Sort by updatedAt
      updatedChats.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

      emit(state.copyWith(
        status: ChatListStatus.loaded,
        chats: updatedChats,
        selectedChat: state.selectedChat?.uuid == event.uuid
            ? updated
            : state.selectedChat,
      ));
    } catch (e) {
      _log.error('[ChatListBloc] Error updating chat: {error}', parameters: {'error': e});
      emit(state.copyWith(
        status: ChatListStatus.error,
        errorMessage: 'Failed to update chat: $e',
      ));
    }
  }

  /// Delete chat from local storage
  Future<void> _onDeleteChat(
    ChatListDeleteChat event,
    Emitter<ChatListState> emit,
  ) async {
    try {
      await _repository.deleteChat(event.uuid);
      _log.info('[ChatListBloc] Deleted chat: {uuid}', parameters: {'uuid': event.uuid});

      final updatedChats =
          state.chats.where((c) => c.uuid != event.uuid).toList();

      emit(state.copyWith(
        status: ChatListStatus.loaded,
        chats: updatedChats,
        selectedChat:
            state.selectedChat?.uuid == event.uuid ? null : state.selectedChat,
      ));
    } catch (e) {
      _log.error('[ChatListBloc] Error deleting chat: {error}', parameters: {'error': e});
      emit(state.copyWith(
        status: ChatListStatus.error,
        errorMessage: 'Failed to delete chat: $e',
      ));
    }
  }

  /// Mute/unmute a chat (local-only preference).
  Future<void> _onSetMuted(
    ChatListSetMuted event,
    Emitter<ChatListState> emit,
  ) async {
    try {
      final chatToUpdate = state.chats.firstWhere(
        (c) =>
            c.uuid == event.uuid &&
            c.serverAddress.trim() == event.serverAddress.trim(),
        orElse: () => throw Exception('Chat not found'),
      );

      final updated = chatToUpdate.copyWith(
        isMuted: event.muted,
        updatedAt: DateTime.now(),
      );
      await _repository.updateChat(updated);

      final updatedChats = state.chats
          .map((c) => (c.uuid == event.uuid &&
                  c.serverAddress.trim() == event.serverAddress.trim())
              ? updated
              : c)
          .toList()
        ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

      emit(state.copyWith(
        status: ChatListStatus.loaded,
        chats: updatedChats,
        selectedChat: state.selectedChat?.uuid == event.uuid
            ? updated
            : state.selectedChat,
      ));
    } catch (e) {
      _log.error('[ChatListBloc] Error muting chat: {error}',
          parameters: {'error': e});
    }
  }

  /// Refresh chats from disk
  Future<void> _onRefresh(
    ChatListRefresh event,
    Emitter<ChatListState> emit,
  ) async {
    try {
      final chats = await _repository.loadAllChats();
      emit(state.copyWith(
        status: ChatListStatus.loaded,
        chats: chats,
      ));
      _log.info('[ChatListBloc] Refreshed chat list');
    } catch (e) {
      _log.error('[ChatListBloc] Error refreshing: {error}', parameters: {'error': e});
    }
  }

  /// Select a chat to open
  Future<void> _onSelectChat(
    ChatListSelectChat event,
    Emitter<ChatListState> emit,
  ) async {
    emit(state.copyWith(selectedChat: event.chat));
    _log.debug('[ChatListBloc] Selected chat: {uuid}', parameters: {'uuid': event.chat.uuid});
  }

  /// Update window size (desktop only)
  Future<void> _onUpdateWindowSize(
    ChatListUpdateWindowSize event,
    Emitter<ChatListState> emit,
  ) async {
    try {
      final chatToUpdate = state.chats.firstWhere(
        (c) => c.uuid == event.chatUUID,
        orElse: () => throw Exception('Chat not found'),
      );

      final updated = chatToUpdate.copyWith(
        windowWidth: event.width,
        windowHeight: event.height,
        updatedAt: DateTime.now(),
      );

      await _repository.updateChat(updated);

      final updatedChats = state.chats
          .map((c) => c.uuid == event.chatUUID ? updated : c)
          .toList();

      emit(state.copyWith(
        chats: updatedChats,
        selectedChat: state.selectedChat?.uuid == event.chatUUID
            ? updated
            : state.selectedChat,
      ));

      _log.info('[ChatListBloc] Updated window size for {uuid}', parameters: {'uuid': event.chatUUID});
    } catch (e) {
      _log.error('[ChatListBloc] Error updating window size: {error}', parameters: {'error': e});
    }
  }

  /// Received chat metadata from network
  Future<void> _onMetadataReceived(
    ChatListMetadataReceived event,
    Emitter<ChatListState> emit,
  ) async {
    // This updates local metadata based on what other peers sent
    // Usually you'd merge or ask user to confirm
    _log.info('[ChatListBloc] Received metadata from {sender}: chatName={chatName}, avatarBytes={avatarSize}', parameters: {'sender': event.senderUUID, 'chatName': event.chatName, 'avatarSize': event.avatarBytes?.length ?? 0});
  }
}
