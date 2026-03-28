part of 'chat_list_bloc.dart';

/// Base event for ChatListBloc
sealed class ChatListEvent {}

/// Load all saved chats from disk
class ChatListLoadChats extends ChatListEvent {
  ChatListLoadChats();
}

/// Create a new chat
class ChatListCreateChat extends ChatListEvent {
  final String name;
  final Uint8List? avatarBytes;

  ChatListCreateChat({
    required this.name,
    this.avatarBytes,
  });
}

/// Update existing chat metadata
class ChatListUpdateChat extends ChatListEvent {
  final String uuid;
  final String? newName;
  final Uint8List? newAvatarBytes;

  ChatListUpdateChat({
    required this.uuid,
    this.newName,
    this.newAvatarBytes,
  });
}

/// Delete chat from local storage
class ChatListDeleteChat extends ChatListEvent {
  final String uuid;

  ChatListDeleteChat({required this.uuid});
}

/// Refresh chat list from disk
class ChatListRefresh extends ChatListEvent {
  ChatListRefresh();
}

/// Select a chat to open
class ChatListSelectChat extends ChatListEvent {
  final ChatMetadata chat;

  ChatListSelectChat({required this.chat});
}

/// Update window size for desktop (saves to metadata)
class ChatListUpdateWindowSize extends ChatListEvent {
  final String chatUUID;
  final int width;
  final int height;

  ChatListUpdateWindowSize({
    required this.chatUUID,
    required this.width,
    required this.height,
  });
}

/// Internal event: received chat metadata from network
class ChatListMetadataReceived extends ChatListEvent {
  final String senderUUID;
  final String chatName;
  final Uint8List? avatarBytes;

  ChatListMetadataReceived({
    required this.senderUUID,
    required this.chatName,
    this.avatarBytes,
  });
}
