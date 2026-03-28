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
  final Map<String, String> nicknames;
  const ChatConnect(this.config, {this.nicknames = const {}});
  @override
  List<Object?> get props => [config, nicknames];
}

/// Reconnect using the last known config (e.g. after disconnect).
class ChatReconnect extends ChatEvent {
  const ChatReconnect();
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
  List<Object?> get props => [name, mime];
}

class ChatSendVideo extends ChatEvent {
  final Uint8List bytes;
  final String name;
  final String mime;
  const ChatSendVideo({required this.bytes, required this.name, required this.mime});
  @override
  List<Object?> get props => [name, mime];
}

class ChatSendVoice extends ChatEvent {
  final Uint8List bytes;
  final String mime;
  const ChatSendVoice({required this.bytes, required this.mime});
  @override
  List<Object?> get props => [mime];
}

class ChatDisconnect extends ChatEvent {
  const ChatDisconnect();
}

/// Update chat name and/or avatar — broadcasted to all peers.
class ChatUpdateMetadata extends ChatEvent {
  final String name;
  final Uint8List? avatarBytes;
  const ChatUpdateMetadata({required this.name, this.avatarBytes});
  @override
  List<Object?> get props => [name];
}

class ChatInternalSgtpEvent extends ChatEvent {
  final SgtpEvent sgtpEvent;
  const ChatInternalSgtpEvent(this.sgtpEvent);
  @override
  List<Object?> get props => [sgtpEvent];
}
