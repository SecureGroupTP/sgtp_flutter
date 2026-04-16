import 'dart:typed_data';
import 'package:equatable/equatable.dart';
import 'package:sgtp_flutter/features/messaging/domain/entities/message.dart';

enum ChatStatus { connecting, handshaking, ready, error, disconnected }

class ChatState extends Equatable {
  final ChatStatus status;
  final List<ChatMessage> messages;
  final List<String> peerUUIDs;
  final bool isMaster;
  final String roomUUID;
  final String myUUID;
  final String myPublicKeyHex;
  final String? errorMessage;

  /// Whitelist: ed25519PubHex → nickname (from whitelist file names).
  final Map<String, String> nicknames;

  /// Runtime: sessionUUID → nickname (populated as peers join).
  final Map<String, String> peerNicknames;

  /// History: sessionUUID → nickname (preserved after peer leaves).
  final Map<String, String> peerNicknamesHistory;

  /// History: sessionUUID → ed25519PubHex (preserved after peer leaves).
  final Map<String, String> peerPublicKeys;

  /// Current chat display name (can be updated by any participant).
  final String chatName;

  /// Current chat avatar bytes (PNG/JPEG, max 4 KB).
  final Uint8List? chatAvatarBytes;

  /// True when this room is explicitly marked as a direct message chat
  /// (created from Contacts -> Message).
  final bool isDirectChat;

  /// The local user's own avatar bytes (for display next to own messages).
  final Uint8List? userAvatarBytes;

  /// Per-peer avatars: sessionUUID → avatar bytes (learned from messages).
  final Map<String, Uint8List> peerAvatars;

  /// Read receipts: messageId → set of readerUUIDs
  final Map<String, Set<String>> readReceipts;

  /// The message currently being replied to (null = no reply).
  final ChatMessage? replyToMessage;

  /// Upload progress 0.0–1.0 (null = idle).
  final double? uploadProgress;

  /// Emoji reactions: messageId → emoji → Set(senderUUID) (local + received).
  final Map<String, Map<String, Set<String>>> reactions;

  /// True while an older history page is being loaded from local storage.
  final bool isLoadingHistory;

  /// Whether there are older local history messages available.
  final bool hasMoreHistory;

  /// Count of unread incoming messages while the chat page is not visible.
  final int unreadCount;

  const ChatState({
    this.status = ChatStatus.connecting,
    this.messages = const [],
    this.peerUUIDs = const [],
    this.isMaster = false,
    this.roomUUID = '',
    this.myUUID = '',
    this.myPublicKeyHex = '',
    this.errorMessage,
    this.nicknames = const {},
    this.peerNicknames = const {},
    this.peerNicknamesHistory = const {},
    this.peerPublicKeys = const {},
    this.chatName = 'Chat',
    this.chatAvatarBytes,
    this.isDirectChat = false,
    this.userAvatarBytes,
    this.peerAvatars = const {},
    this.readReceipts = const {},
    this.replyToMessage,
    this.uploadProgress,
    this.reactions = const {},
    this.isLoadingHistory = false,
    this.hasMoreHistory = true,
    this.unreadCount = 0,
  });

  ChatState copyWith({
    ChatStatus? status,
    List<ChatMessage>? messages,
    List<String>? peerUUIDs,
    bool? isMaster,
    String? roomUUID,
    String? myUUID,
    String? myPublicKeyHex,
    String? errorMessage,
    Map<String, String>? nicknames,
    Map<String, String>? peerNicknames,
    Map<String, String>? peerNicknamesHistory,
    Map<String, String>? peerPublicKeys,
    String? chatName,
    Uint8List? chatAvatarBytes,
    bool? isDirectChat,
    Uint8List? userAvatarBytes,
    Map<String, Uint8List>? peerAvatars,
    Map<String, Set<String>>? readReceipts,
    ChatMessage? replyToMessage,
    double? uploadProgress,
    Map<String, Map<String, Set<String>>>? reactions,
    bool? isLoadingHistory,
    bool? hasMoreHistory,
    int? unreadCount,
    bool clearError = false,
    bool clearAvatar = false,
    bool clearUserAvatar = false,
    bool clearReply = false,
    bool clearUpload = false,
  }) {
    return ChatState(
      status: status ?? this.status,
      messages: messages ?? this.messages,
      peerUUIDs: peerUUIDs ?? this.peerUUIDs,
      isMaster: isMaster ?? this.isMaster,
      roomUUID: roomUUID ?? this.roomUUID,
      myUUID: myUUID ?? this.myUUID,
      myPublicKeyHex: myPublicKeyHex ?? this.myPublicKeyHex,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      nicknames: nicknames ?? this.nicknames,
      peerNicknames: peerNicknames ?? this.peerNicknames,
      peerNicknamesHistory: peerNicknamesHistory ?? this.peerNicknamesHistory,
      peerPublicKeys: peerPublicKeys ?? this.peerPublicKeys,
      chatName: chatName ?? this.chatName,
      chatAvatarBytes:
          clearAvatar ? null : (chatAvatarBytes ?? this.chatAvatarBytes),
      isDirectChat: isDirectChat ?? this.isDirectChat,
      userAvatarBytes:
          clearUserAvatar ? null : (userAvatarBytes ?? this.userAvatarBytes),
      peerAvatars: peerAvatars ?? this.peerAvatars,
      readReceipts: readReceipts ?? this.readReceipts,
      replyToMessage:
          clearReply ? null : (replyToMessage ?? this.replyToMessage),
      uploadProgress:
          clearUpload ? null : (uploadProgress ?? this.uploadProgress),
      reactions: reactions ?? this.reactions,
      isLoadingHistory: isLoadingHistory ?? this.isLoadingHistory,
      hasMoreHistory: hasMoreHistory ?? this.hasMoreHistory,
      unreadCount: unreadCount ?? this.unreadCount,
    );
  }

  @override
  List<Object?> get props => [
        status,
        messages,
        peerUUIDs,
        isMaster,
        roomUUID,
        myUUID,
        myPublicKeyHex,
        errorMessage,
        nicknames,
        peerNicknames,
        peerNicknamesHistory,
        peerPublicKeys,
        chatName,
        chatAvatarBytes,
        isDirectChat,
        userAvatarBytes,
        peerAvatars,
        readReceipts,
        replyToMessage,
        uploadProgress,
        reactions,
        isLoadingHistory,
        hasMoreHistory,
        unreadCount,
      ];
}
