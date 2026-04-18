import 'dart:typed_data';
import 'package:equatable/equatable.dart';

/// Represents chat metadata: name, avatar, and window state (for desktop)
class ChatMetadata extends Equatable {
  /// Room UUID (hex-encoded, 32 chars)
  final String uuid;

  /// Chat display name (editable by any participant)
  final String name;

  /// Server address bound to this chat history (host:port).
  final String serverAddress;

  /// Optional server-side room UUID for RPC-based runtimes.
  final String? remoteRoomId;

  /// Avatar image bytes (optional, PNG/JPEG, max 4KB)
  final Uint8List? avatarBytes;

  /// Whether notifications for this chat are muted (local-only preference).
  final bool isMuted;

  /// True only for chats created from Contacts -> Message (direct message).
  final bool isDirectMessage;

  /// Creation timestamp
  final DateTime createdAt;

  /// Last modification timestamp
  final DateTime updatedAt;

  /// Desktop only: window width (preserved between launches)
  final int? windowWidth;

  /// Desktop only: window height (preserved between launches)
  final int? windowHeight;

  const ChatMetadata({
    required this.uuid,
    required this.name,
    required this.serverAddress,
    this.remoteRoomId,
    this.avatarBytes,
    this.isMuted = false,
    this.isDirectMessage = false,
    required this.createdAt,
    required this.updatedAt,
    this.windowWidth,
    this.windowHeight,
  });

  /// Create a copy with modified fields
  ChatMetadata copyWith({
    String? uuid,
    String? name,
    String? serverAddress,
    String? remoteRoomId,
    Uint8List? avatarBytes,
    bool? isMuted,
    bool? isDirectMessage,
    DateTime? createdAt,
    DateTime? updatedAt,
    int? windowWidth,
    int? windowHeight,
  }) {
    return ChatMetadata(
      uuid: uuid ?? this.uuid,
      name: name ?? this.name,
      serverAddress: serverAddress ?? this.serverAddress,
      remoteRoomId: remoteRoomId ?? this.remoteRoomId,
      avatarBytes: avatarBytes ?? this.avatarBytes,
      isMuted: isMuted ?? this.isMuted,
      isDirectMessage: isDirectMessage ?? this.isDirectMessage,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      windowWidth: windowWidth ?? this.windowWidth,
      windowHeight: windowHeight ?? this.windowHeight,
    );
  }

  @override
  List<Object?> get props => [
        uuid,
        name,
        serverAddress,
        remoteRoomId,
        avatarBytes,
        isMuted,
        isDirectMessage,
        createdAt,
        updatedAt,
        windowWidth,
        windowHeight,
      ];
}
