import 'dart:typed_data';
import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter/foundation.dart' show debugPrint;

import 'package:sgtp_flutter/features/messaging/application/models/messaging_models.dart';
import 'package:sgtp_flutter/core/uuid_v7.dart';
import 'package:sgtp_flutter/features/messaging/domain/repositories/chat_storage_gateway.dart';

part 'chat_list_event.dart';
part 'chat_list_state.dart';

/// BLoC для управления списком сохраненных чатов и их метаданными
class ChatListBloc extends Bloc<ChatListEvent, ChatListState> {
  final ChatMetadataStore _repository;

  ChatListBloc({required ChatMetadataStore repository})
      : _repository = repository,
        super(const ChatListState()) {
    on<ChatListLoadChats>(_onLoadChats);
    on<ChatListCreateChat>(_onCreateChat);
    on<ChatListUpdateChat>(_onUpdateChat);
    on<ChatListDeleteChat>(_onDeleteChat);
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
      debugPrint('[ChatListBloc] Loaded ${chats.length} chats');

      emit(state.copyWith(
        status: ChatListStatus.loaded,
        chats: chats,
      ));
    } catch (e) {
      debugPrint('[ChatListBloc] Error loading chats: $e');
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
      debugPrint('[ChatListBloc] Created chat: $uuid');

      final updatedChats = [newChat, ...state.chats];
      emit(state.copyWith(
        status: ChatListStatus.loaded,
        chats: updatedChats,
        selectedChat: newChat,
      ));
    } catch (e) {
      debugPrint('[ChatListBloc] Error creating chat: $e');
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
      debugPrint('[ChatListBloc] Updated chat: ${event.uuid}');

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
      debugPrint('[ChatListBloc] Error updating chat: $e');
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
      debugPrint('[ChatListBloc] Deleted chat: ${event.uuid}');

      final updatedChats =
          state.chats.where((c) => c.uuid != event.uuid).toList();

      emit(state.copyWith(
        status: ChatListStatus.loaded,
        chats: updatedChats,
        selectedChat:
            state.selectedChat?.uuid == event.uuid ? null : state.selectedChat,
      ));
    } catch (e) {
      debugPrint('[ChatListBloc] Error deleting chat: $e');
      emit(state.copyWith(
        status: ChatListStatus.error,
        errorMessage: 'Failed to delete chat: $e',
      ));
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
      debugPrint('[ChatListBloc] Refreshed chat list');
    } catch (e) {
      debugPrint('[ChatListBloc] Error refreshing: $e');
    }
  }

  /// Select a chat to open
  Future<void> _onSelectChat(
    ChatListSelectChat event,
    Emitter<ChatListState> emit,
  ) async {
    emit(state.copyWith(selectedChat: event.chat));
    debugPrint('[ChatListBloc] Selected chat: ${event.chat.uuid}');
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

      debugPrint('[ChatListBloc] Updated window size for ${event.chatUUID}');
    } catch (e) {
      debugPrint('[ChatListBloc] Error updating window size: $e');
    }
  }

  /// Received chat metadata from network
  Future<void> _onMetadataReceived(
    ChatListMetadataReceived event,
    Emitter<ChatListState> emit,
  ) async {
    // This updates local metadata based on what other peers sent
    // Usually you'd merge or ask user to confirm
    debugPrint('[ChatListBloc] Received metadata from ${event.senderUUID}');
    debugPrint('  Chat name: ${event.chatName}');
    debugPrint('  Avatar: ${event.avatarBytes?.length ?? 0} bytes');
  }
}
