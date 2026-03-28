import 'dart:typed_data';
import 'package:equatable/equatable.dart';

/// Represents chat metadata: name, avatar, and window state (for desktop)
class ChatMetadata extends Equatable {
  /// Room UUID (hex-encoded, 32 chars)
  final String uuid;

  /// Chat display name (editable by any participant)
  final String name;

  /// Avatar image bytes (optional, PNG/JPEG, max 4KB)
  final Uint8List? avatarBytes;

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
    this.avatarBytes,
    required this.createdAt,
    required this.updatedAt,
    this.windowWidth,
    this.windowHeight,
  });

  /// Create a copy with modified fields
  ChatMetadata copyWith({
    String? uuid,
    String? name,
    Uint8List? avatarBytes,
    DateTime? createdAt,
    DateTime? updatedAt,
    int? windowWidth,
    int? windowHeight,
  }) {
    return ChatMetadata(
      uuid: uuid ?? this.uuid,
      name: name ?? this.name,
      avatarBytes: avatarBytes ?? this.avatarBytes,
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
        avatarBytes,
        createdAt,
        updatedAt,
        windowWidth,
        windowHeight,
      ];
}
