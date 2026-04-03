import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:path_provider/path_provider.dart';

import '../../domain/entities/chat_metadata.dart';

/// Repository for persisting chat metadata to disk.
/// Metadata includes: chat name, avatar, server address, window size (desktop).
class ChatMetadataRepository {
  static const String _legacyChatsDir = 'sgtp_chats';
  static const String _accountsDir = 'sgtp_accounts';
  static const String _chatsDirName = 'sgtp_chats';

  final String? accountId;

  ChatMetadataRepository({this.accountId});

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

  String _serverKey(String serverAddress) {
    final normalized = serverAddress.trim().toLowerCase();
    if (normalized.isEmpty) return 'default';
    return base64Url.encode(utf8.encode(normalized)).replaceAll('=', '');
  }

  Future<Directory> _getChatDirectory(String uuid,
      {required String serverAddress}) async {
    final chatsDir = await _getChatsDirectory();
    final serverDir =
        Directory('${chatsDir.path}/${_serverKey(serverAddress)}');
    if (!await serverDir.exists()) {
      await serverDir.create(recursive: true);
    }
    return Directory('${serverDir.path}/$uuid');
  }

  Future<File> _getMetadataFile(String chatUUID,
      {required String serverAddress}) async {
    final chatDir =
        await _getChatDirectory(chatUUID, serverAddress: serverAddress);
    return File('${chatDir.path}/metadata.json');
  }

  Future<List<ChatMetadata>> loadAllChats() async {
    try {
      final chatsDir = await _getChatsDirectory();
      if (!await chatsDir.exists()) return [];

      final chats = <ChatMetadata>[];
      final dirs = chatsDir.listSync().whereType<Directory>();

      for (final entry in dirs) {
        final directMetadata = File('${entry.path}/metadata.json');
        if (await directMetadata.exists()) {
          final uuid = _basename(entry.path);
          final chat = await _loadLegacyChat(uuid);
          if (chat != null) chats.add(chat);
          continue;
        }

        final nested = entry.listSync().whereType<Directory>();
        for (final chatDir in nested) {
          final uuid = _basename(chatDir.path);
          final file = File('${chatDir.path}/metadata.json');
          if (!await file.exists()) continue;
          try {
            final parsed =
                jsonDecode(await file.readAsString()) as Map<String, dynamic>;
            chats.add(_parseJson(uuid, parsed));
          } catch (e) {
            debugPrint('[ChatMetadata] Error parsing chat $uuid: $e');
          }
        }
      }

      chats.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      return chats;
    } catch (e) {
      debugPrint('[ChatMetadata] Error loading chats: $e');
      return [];
    }
  }

  String _basename(String path) {
    if (path.isEmpty) return path;
    final normalized = path.replaceAll('\\', '/');
    final idx = normalized.lastIndexOf('/');
    return idx >= 0 ? normalized.substring(idx + 1) : normalized;
  }

  Future<ChatMetadata?> _loadLegacyChat(String uuid) async {
    try {
      final chatsDir = await _getChatsDirectory();
      final file = File('${chatsDir.path}/$uuid/metadata.json');
      if (!await file.exists()) return null;
      final content = await file.readAsString();
      final json = jsonDecode(content) as Map<String, dynamic>;
      return _parseJson(uuid, json);
    } catch (e) {
      debugPrint('[ChatMetadata] Error loading legacy chat $uuid: $e');
      return null;
    }
  }

  Future<ChatMetadata?> loadChat(String uuid, {String? serverAddress}) async {
    try {
      final server = (serverAddress ?? '').trim();
      if (server.isNotEmpty) {
        final file = await _getMetadataFile(uuid, serverAddress: server);
        if (await file.exists()) {
          final content = await file.readAsString();
          final json = jsonDecode(content) as Map<String, dynamic>;
          return _parseJson(uuid, json, fallbackServerAddress: server);
        }
        // Backward-compat: read old non-server-scoped location for this UUID.
        final chatsDir = await _getChatsDirectory();
        final legacyFile = File('${chatsDir.path}/$uuid/metadata.json');
        if (await legacyFile.exists()) {
          final content = await legacyFile.readAsString();
          final json = jsonDecode(content) as Map<String, dynamic>;
          return _parseJson(uuid, json, fallbackServerAddress: server);
        }
        // Important: when server is specified, never fallback to another server.
        return null;
      }

      final all = await loadAllChats();
      for (final chat in all) {
        if (chat.uuid == uuid) return chat;
      }
      return null;
    } catch (e) {
      debugPrint('[ChatMetadata] Error loading chat $uuid: $e');
      return null;
    }
  }

  Future<void> saveChat(ChatMetadata metadata) async {
    try {
      final file = await _getMetadataFile(
        metadata.uuid,
        serverAddress: metadata.serverAddress,
      );
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode(_toJson(metadata)), flush: true);
      debugPrint(
          '[ChatMetadata] Saved chat: ${metadata.uuid}@${metadata.serverAddress}');
    } catch (e) {
      debugPrint('[ChatMetadata] Error saving chat: $e');
      rethrow;
    }
  }

  Future<void> updateChat(ChatMetadata metadata) async {
    try {
      final updated = metadata.copyWith(updatedAt: DateTime.now());
      await saveChat(updated);
      debugPrint('[ChatMetadata] Updated chat: ${metadata.uuid}');
    } catch (e) {
      debugPrint('[ChatMetadata] Error updating chat: $e');
      rethrow;
    }
  }

  Future<void> deleteChat(String uuid, {String? serverAddress}) async {
    try {
      final chatsDir = await _getChatsDirectory();
      final server = (serverAddress ?? '').trim();

      if (server.isNotEmpty) {
        final scoped = await _getChatDirectory(uuid, serverAddress: server);
        if (await scoped.exists()) {
          await scoped.delete(recursive: true);
        }
      } else {
        final legacyDir = Directory('${chatsDir.path}/$uuid');
        if (await legacyDir.exists()) {
          await legacyDir.delete(recursive: true);
        }

        final servers = chatsDir.listSync().whereType<Directory>();
        for (final serverDir in servers) {
          final scoped = Directory('${serverDir.path}/$uuid');
          if (await scoped.exists()) {
            await scoped.delete(recursive: true);
          }
        }
      }

      debugPrint(
          '[ChatMetadata] Deleted chat: $uuid${server.isNotEmpty ? '@$server' : ''}');
    } catch (e) {
      debugPrint('[ChatMetadata] Error deleting chat: $e');
      rethrow;
    }
  }

  Map<String, dynamic> _toJson(ChatMetadata metadata) {
    return {
      'uuid': metadata.uuid,
      'name': metadata.name,
      'serverAddress': metadata.serverAddress,
      'avatar': metadata.avatarBytes != null
          ? base64Encode(metadata.avatarBytes!)
          : null,
      'createdAt': metadata.createdAt.toIso8601String(),
      'updatedAt': metadata.updatedAt.toIso8601String(),
      'windowWidth': metadata.windowWidth,
      'windowHeight': metadata.windowHeight,
    };
  }

  ChatMetadata _parseJson(
    String uuid,
    Map<String, dynamic> json, {
    String? fallbackServerAddress,
  }) {
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
      serverAddress:
          (json['serverAddress'] as String? ?? fallbackServerAddress ?? '')
              .trim(),
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
