import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:flutter/foundation.dart' show debugPrint;

import '../../domain/entities/chat_metadata.dart';

/// Repository for persisting chat metadata to disk.
/// Metadata includes: chat name, avatar, window size (desktop).
/// Message history is NOT stored here.
class ChatMetadataRepository {
  static const String _legacyChatsDir = 'sgtp_chats';
  static const String _accountsDir = 'sgtp_accounts';
  static const String _chatsDirName = 'sgtp_chats';

  final String? accountId;

  ChatMetadataRepository({this.accountId});

  /// Get the chats directory path
  Future<Directory> _getChatsDirectory() async {
    final docsDir = await getApplicationDocumentsDirectory();
    final id = (accountId ?? '').trim();
    final chatsDir = id.isEmpty
        ? Directory('${docsDir.path}/$_legacyChatsDir')
        : Directory('${docsDir.path}/$_accountsDir/$id/$_chatsDirName');
    if (!await chatsDir.exists()) {
      await chatsDir.create(recursive: true);
    }
    return chatsDir;
  }

  /// Get metadata file for a specific chat
  Future<File> _getMetadataFile(String chatUUID) async {
    final chatsDir = await _getChatsDirectory();
    return File('${chatsDir.path}/$chatUUID/metadata.json');
  }

  /// Load all saved chats
  Future<List<ChatMetadata>> loadAllChats() async {
    try {
      final chatsDir = await _getChatsDirectory();
      if (!await chatsDir.exists()) return [];

      final chats = <ChatMetadata>[];
      final dirs = chatsDir.listSync();

      for (final entry in dirs) {
        if (entry is Directory) {
          final uuid = p.basename(entry.path);
          final chat = await loadChat(uuid);
          if (chat != null) {
            chats.add(chat);
          }
        }
      }

      // Sort by updatedAt descending (most recent first)
      chats.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      return chats;
    } catch (e) {
      debugPrint('[ChatMetadata] Error loading chats: $e');
      return [];
    }
  }

  /// Load a specific chat by UUID
  Future<ChatMetadata?> loadChat(String uuid) async {
    try {
      final file = await _getMetadataFile(uuid);
      if (!await file.exists()) {
        return null;
      }

      final content = await file.readAsString();
      final json = jsonDecode(content) as Map<String, dynamic>;
      return _parseJson(uuid, json);
    } catch (e) {
      debugPrint('[ChatMetadata] Error loading chat $uuid: $e');
      return null;
    }
  }

  /// Save a new chat or update an existing one
  Future<void> saveChat(ChatMetadata metadata) async {
    try {
      final file = await _getMetadataFile(metadata.uuid);
      await file.parent.create(recursive: true);

      final json = _toJson(metadata);
      await file.writeAsString(
        jsonEncode(json),
        flush: true,
      );

      debugPrint('[ChatMetadata] Saved chat: ${metadata.uuid}');
    } catch (e) {
      debugPrint('[ChatMetadata] Error saving chat: $e');
      rethrow;
    }
  }

  /// Update an existing chat
  Future<void> updateChat(ChatMetadata metadata) async {
    try {
      final updated = metadata.copyWith(
        updatedAt: DateTime.now(),
      );
      await saveChat(updated);
      debugPrint('[ChatMetadata] Updated chat: ${metadata.uuid}');
    } catch (e) {
      debugPrint('[ChatMetadata] Error updating chat: $e');
      rethrow;
    }
  }

  /// Delete a chat from disk
  Future<void> deleteChat(String uuid) async {
    try {
      final chatsDir = await _getChatsDirectory();
      final chatDir = Directory('${chatsDir.path}/$uuid');
      if (await chatDir.exists()) {
        await chatDir.delete(recursive: true);
      }
      debugPrint('[ChatMetadata] Deleted chat: $uuid');
    } catch (e) {
      debugPrint('[ChatMetadata] Error deleting chat: $e');
      rethrow;
    }
  }

  /// Convert ChatMetadata to JSON
  Map<String, dynamic> _toJson(ChatMetadata metadata) {
    return {
      'uuid': metadata.uuid,
      'name': metadata.name,
      // Store avatar as base64 for JSON compatibility
      'avatar': metadata.avatarBytes != null
          ? base64Encode(metadata.avatarBytes!)
          : null,
      'createdAt': metadata.createdAt.toIso8601String(),
      'updatedAt': metadata.updatedAt.toIso8601String(),
      'windowWidth': metadata.windowWidth,
      'windowHeight': metadata.windowHeight,
    };
  }

  /// Parse JSON to ChatMetadata
  ChatMetadata _parseJson(String uuid, Map<String, dynamic> json) {
    final avatarBase64 = json['avatar'] as String?;
    Uint8List? avatarBytes;
    if (avatarBase64 != null && avatarBase64.isNotEmpty) {
      try {
        avatarBytes = base64Decode(avatarBase64);
      } catch (e) {
        debugPrint('[ChatMetadata] Failed to decode avatar: $e');
      }
    }

    return ChatMetadata(
      uuid: uuid,
      name: json['name'] as String? ?? 'Chat',
      avatarBytes: avatarBytes,
      createdAt: DateTime.parse(
          json['createdAt'] as String? ?? DateTime.now().toIso8601String()),
      updatedAt: DateTime.parse(
          json['updatedAt'] as String? ?? DateTime.now().toIso8601String()),
      windowWidth: json['windowWidth'] as int?,
      windowHeight: json['windowHeight'] as int?,
    );
  }
}
