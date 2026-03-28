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

  /// Current chat display name (can be updated by any participant).
  final String chatName;

  /// Current chat avatar bytes (PNG/JPEG, max 4 KB).
  final Uint8List? chatAvatarBytes;

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
    this.chatName = 'Chat',
    this.chatAvatarBytes,
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
    String? chatName,
    Uint8List? chatAvatarBytes,
    bool clearError = false,
    bool clearAvatar = false,
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
      chatName:       chatName ?? this.chatName,
      chatAvatarBytes: clearAvatar ? null : (chatAvatarBytes ?? this.chatAvatarBytes),
    );
  }

  @override
  List<Object?> get props => [
        status, messages, peerUUIDs, isMaster,
        roomUUID, myUUID, myPublicKeyHex, errorMessage,
        nicknames, peerNicknames, peerNicknamesHistory,
        chatName, chatAvatarBytes,
      ];
}
