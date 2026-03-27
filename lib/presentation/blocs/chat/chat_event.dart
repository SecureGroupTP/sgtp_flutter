import 'dart:typed_data';

import 'package:equatable/equatable.dart';

import '../../../data/sgtp_client.dart';

abstract class ChatEvent extends Equatable {
  const ChatEvent();
  @override
  List<Object?> get props => [];
}

class ChatConnect extends ChatEvent {
  final SgtpConfig config;
  const ChatConnect(this.config);
  @override
  List<Object?> get props => [config];
}

class ChatSendMessage extends ChatEvent {
  final String text;
  const ChatSendMessage(this.text);
  @override
  List<Object?> get props => [text];
}

class ChatSendImage extends ChatEvent {
  final Uint8List bytes;
  final String name;
  final String mime;
  const ChatSendImage({required this.bytes, required this.name, required this.mime});
  @override
  List<Object?> get props => [bytes, name, mime];
}

class ChatDisconnect extends ChatEvent {
  const ChatDisconnect();
}

// Internal event carrying SgtpEvent from the client stream
class ChatInternalSgtpEvent extends ChatEvent {
  final SgtpEvent sgtpEvent;
  const ChatInternalSgtpEvent(this.sgtpEvent);
  @override
  List<Object?> get props => [sgtpEvent];
}
