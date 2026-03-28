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
  /// ed25519PubHex → nickname, built from whitelist file names.
  final Map<String, String> nicknames;

  const ChatConnect(this.config, {this.nicknames = const {}});

  @override
  List<Object?> get props => [config, nicknames];
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

class ChatInternalSgtpEvent extends ChatEvent {
  final SgtpEvent sgtpEvent;
  const ChatInternalSgtpEvent(this.sgtpEvent);
  @override
  List<Object?> get props => [sgtpEvent];
}
