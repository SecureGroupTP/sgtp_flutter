import 'dart:typed_data';
import 'package:equatable/equatable.dart';
import '../../../domain/entities/message.dart';

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

  /// Emoji reactions: messageId → emoji → Set<senderUUID> (local + received).
  final Map<String, Map<String, Set<String>>> reactions;

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
    this.userAvatarBytes,
    this.peerAvatars = const {},
    this.readReceipts = const {},
    this.replyToMessage,
    this.uploadProgress,
    this.reactions = const {},
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
    Uint8List? userAvatarBytes,
    Map<String, Uint8List>? peerAvatars,
    Map<String, Set<String>>? readReceipts,
    ChatMessage? replyToMessage,
    double? uploadProgress,
    Map<String, Map<String, Set<String>>>? reactions,
    bool clearError = false,
    bool clearAvatar = false,
    bool clearUserAvatar = false,
    bool clearReply = false,
    bool clearUpload = false,
  }) {
    return ChatState(
      status:         status ?? this.status,
      messages:       messages ?? this.messages,
      peerUUIDs:      peerUUIDs ?? this.peerUUIDs,
      isMaster:       isMaster ?? this.isMaster,
      roomUUID:       roomUUID ?? this.roomUUID,
      myUUID:         myUUID ?? this.myUUID,
      myPublicKeyHex: myPublicKeyHex ?? this.myPublicKeyHex,
      errorMessage:   clearError ? null : (errorMessage ?? this.errorMessage),
      nicknames:      nicknames ?? this.nicknames,
      peerNicknames:  peerNicknames ?? this.peerNicknames,
      peerNicknamesHistory: peerNicknamesHistory ?? this.peerNicknamesHistory,
      peerPublicKeys: peerPublicKeys ?? this.peerPublicKeys,
      chatName:       chatName ?? this.chatName,
      chatAvatarBytes: clearAvatar ? null : (chatAvatarBytes ?? this.chatAvatarBytes),
      userAvatarBytes: clearUserAvatar ? null : (userAvatarBytes ?? this.userAvatarBytes),
      peerAvatars:    peerAvatars ?? this.peerAvatars,
      readReceipts:   readReceipts ?? this.readReceipts,
      replyToMessage: clearReply ? null : (replyToMessage ?? this.replyToMessage),
      uploadProgress: clearUpload ? null : (uploadProgress ?? this.uploadProgress),
      reactions:      reactions ?? this.reactions,
    );
  }

  @override
  List<Object?> get props => [
        status, messages, peerUUIDs, isMaster,
        roomUUID, myUUID, myPublicKeyHex, errorMessage,
        nicknames, peerNicknames, peerNicknamesHistory, peerPublicKeys,
        chatName, chatAvatarBytes, userAvatarBytes,
        peerAvatars, readReceipts, replyToMessage, uploadProgress, reactions,
      ];
}
