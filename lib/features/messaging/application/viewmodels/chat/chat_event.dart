import 'dart:typed_data';
import 'package:cross_file/cross_file.dart';
import 'package:equatable/equatable.dart';
import 'package:sgtp_flutter/features/messaging/application/models/messaging_models.dart';
import 'package:sgtp_flutter/features/messaging/domain/repositories/i_sgtp_session.dart';
import 'package:sgtp_flutter/features/messaging/domain/entities/sgtp_config.dart';

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

/// Probe the existing connection after app resume without forcing reconnect.
class ChatProbeConnection extends ChatEvent {
  const ChatProbeConnection();
}

/// Marks all currently loaded incoming messages as read (resets unread badge).
class ChatMarkAllRead extends ChatEvent {
  const ChatMarkAllRead();
}

/// Tells the bloc whether the chat page is currently visible to the user.
class ChatSetVisibility extends ChatEvent {
  final bool isVisible;
  const ChatSetVisibility(this.isVisible);
  @override
  List<Object?> get props => [isVisible];
}

class ChatSendMessage extends ChatEvent {
  final String text;
  final String? replyToId;
  final String? replyToContent;
  final String? replyToSender;
  const ChatSendMessage(this.text,
      {this.replyToId, this.replyToContent, this.replyToSender});
  @override
  List<Object?> get props => [text, replyToId];
}

class ChatSendImage extends ChatEvent {
  final Uint8List bytes;
  final String name;
  final String mime;
  const ChatSendImage(
      {required this.bytes, required this.name, required this.mime});
  @override
  List<Object?> get props => [name, mime];
}

class ChatSendVideo extends ChatEvent {
  final XFile xFile;
  final String name;
  final String mime;
  const ChatSendVideo(
      {required this.xFile, required this.name, required this.mime});
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

class ChatSendVideoNote extends ChatEvent {
  final Uint8List bytes;
  final String mime;
  const ChatSendVideoNote({required this.bytes, required this.mime});
  @override
  List<Object?> get props => [mime];
}

/// Video note picked from gallery — streamed from XFile, never fully loaded.
class ChatSendVideoNoteFile extends ChatEvent {
  final XFile xFile;
  final String mime;
  final VideoNoteMetadata? metadata;
  final bool isFrontCameraSource;

  const ChatSendVideoNoteFile({
    required this.xFile,
    required this.mime,
    this.metadata,
    this.isFrontCameraSource = false,
  });
  @override
  List<Object?> get props => [mime, metadata, isFrontCameraSource];
}

/// Send a read receipt for a given message id.
class ChatSendMessageRead extends ChatEvent {
  final String messageId;
  const ChatSendMessageRead(this.messageId);
  @override
  List<Object?> get props => [messageId];
}

/// Load older local history page (from disk) in batches.
class ChatLoadOlderHistory extends ChatEvent {
  const ChatLoadOlderHistory();
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

/// Set the user's own avatar (for display next to own messages).
class ChatSetUserAvatar extends ChatEvent {
  final Uint8List? avatarBytes;
  const ChatSetUserAvatar(this.avatarBytes);
  @override
  List<Object?> get props => [avatarBytes];
}

/// Set the message the user is replying to.
class ChatSetReply extends ChatEvent {
  final ChatMessage message;
  const ChatSetReply(this.message);
  @override
  List<Object?> get props => [message.id];
}

/// Clear the current reply.
class ChatClearReply extends ChatEvent {
  const ChatClearReply();
}

/// Toggle an emoji reaction on a message.
class ChatToggleReaction extends ChatEvent {
  final String messageId;
  final String emoji;
  const ChatToggleReaction({required this.messageId, required this.emoji});
  @override
  List<Object?> get props => [messageId, emoji];
}

/// Hot-update the whitelist on a live connection (no reconnect needed).
class ChatUpdateWhitelist extends ChatEvent {
  final Set<String> whitelist;
  const ChatUpdateWhitelist(this.whitelist);
  @override
  List<Object?> get props => [whitelist];
}

/// Hot-update nicknames (ed25519PubHex → name) without reconnect.
/// Called when the user adds/edits/removes a contact while rooms are live.
class ChatUpdateNicknames extends ChatEvent {
  final Map<String, String> nicknames;
  const ChatUpdateNicknames(this.nicknames);
  @override
  List<Object?> get props => [nicknames];
}

/// Hot-update contact avatars (ed25519PubHex -> avatar bytes).
/// Chat UI maps them to peers via peerPublicKeys.
class ChatUpdateContactAvatars extends ChatEvent {
  final Map<String, Uint8List> avatarsByPubkey;
  const ChatUpdateContactAvatars(this.avatarsByPubkey);
  @override
  List<Object?> get props => [avatarsByPubkey];
}

class ChatInternalSgtpEvent extends ChatEvent {
  final SgtpEvent sgtpEvent;

  /// The session generation counter at the time this event was dispatched.
  /// The BLoC ignores events whose sessionId doesn't match the current one,
  /// preventing stale reconnect events from corrupting the peer list.
  final int sessionId;
  const ChatInternalSgtpEvent(this.sgtpEvent, {this.sessionId = 0});
  @override
  List<Object?> get props => [sgtpEvent, sessionId];
}
