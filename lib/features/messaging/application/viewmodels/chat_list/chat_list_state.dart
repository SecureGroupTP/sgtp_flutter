part of 'chat_list_bloc.dart';

enum ChatListStatus {
  initial,
  loading,
  loaded,
  error,
}

/// State for ChatListBloc
class ChatListState extends Equatable {
  final ChatListStatus status;
  final List<ChatMetadata> chats;
  final ChatMetadata? selectedChat;
  final String? errorMessage;

  const ChatListState({
    this.status = ChatListStatus.initial,
    this.chats = const [],
    this.selectedChat,
    this.errorMessage,
  });

  bool get isLoading => status == ChatListStatus.loading;
  bool get hasError => status == ChatListStatus.error;
  bool get hasChats => chats.isNotEmpty;

  ChatListState copyWith({
    ChatListStatus? status,
    List<ChatMetadata>? chats,
    ChatMetadata? selectedChat,
    String? errorMessage,
  }) {
    return ChatListState(
      status: status ?? this.status,
      chats: chats ?? this.chats,
      selectedChat: selectedChat ?? this.selectedChat,
      errorMessage: errorMessage ?? this.errorMessage,
    );
  }

  ChatListState clearError() {
    return copyWith(
      status: ChatListStatus.loaded,
      errorMessage: null,
    );
  }

  @override
  List<Object?> get props => [status, chats, selectedChat, errorMessage];
}
