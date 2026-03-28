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

  /// Whitelist: ed25519PubHex → nickname (from file names like "friend.pub" → "friend").
  final Map<String, String> nicknames;

  /// Runtime: sessionUUID → nickname (populated as peers join, using [nicknames]).
  final Map<String, String> peerNicknames;

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
    bool clearError = false,
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
    );
  }

  @override
  List<Object?> get props => [
        status, messages, peerUUIDs, isMaster,
        roomUUID, myUUID, myPublicKeyHex, errorMessage,
        nicknames, peerNicknames,
      ];
}
