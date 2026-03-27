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

  const ChatState({
    this.status = ChatStatus.connecting,
    this.messages = const [],
    this.peerUUIDs = const [],
    this.isMaster = false,
    this.roomUUID = '',
    this.myUUID = '',
    this.myPublicKeyHex = '',
    this.errorMessage,
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
    bool clearError = false,
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
      ];
}
