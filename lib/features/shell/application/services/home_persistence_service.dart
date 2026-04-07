import 'dart:typed_data';

import 'package:sgtp_flutter/core/app_logger.dart';
import 'package:sgtp_flutter/features/messaging/domain/entities/chat_metadata.dart';
import 'package:sgtp_flutter/features/messaging/domain/repositories/chat_storage_gateway.dart';
import 'package:sgtp_flutter/features/settings/application/services/settings_management_service.dart';
import 'package:sgtp_flutter/features/shell/application/models/home_models.dart';
import 'package:sgtp_flutter/features/setup/domain/entities/contact_directory_models.dart';

class HomePersistenceService {
  HomePersistenceService({
    required SettingsManagementService settingsManagementService,
    required ChatStorageGateway chatStorageGateway,
  })  : _settings = settingsManagementService,
        _chatStorageGateway = chatStorageGateway;

  final SettingsManagementService _settings;
  final ChatStorageGateway _chatStorageGateway;

  Future<HomeAccountState> loadAccountState(String accountId) async {
    return HomeAccountState(
      nickname: await _settings.loadUserNicknameForNode(accountId),
      username: await _settings.loadUserUsernameForNode(accountId),
      friendStates: await _settings.loadFriendStates(accountId),
      suppressedContacts: await _settings.loadSuppressedContacts(accountId),
    );
  }

  Future<void> saveUsername(String accountId, String username) {
    return _settings.saveUserUsernameForNode(accountId, username);
  }

  Future<void> saveSuppressedContacts(
    String accountId,
    Set<String> suppressedContacts,
  ) {
    return _settings.saveSuppressedContacts(accountId, suppressedContacts);
  }

  Future<void> saveContactProfile(String accountId, ContactProfile profile) {
    return _settings.saveContactProfile(accountId, profile);
  }

  Future<ContactProfile?> loadContactProfile(
    String accountId,
    String pubkeyHex,
  ) {
    return _settings.loadContactProfile(accountId, pubkeyHex);
  }

  Future<Map<String, ContactProfile>> loadAllContactProfiles(String accountId) {
    return _settings.loadAllContactProfiles(accountId);
  }

  Future<void> saveFriendStates(
    String accountId,
    Map<String, FriendStateRecord> friendStates,
  ) {
    return _settings.saveFriendStates(accountId, friendStates);
  }

  Future<void> saveWhitelistEntries(
    String accountId,
    List<WhitelistEntry> entries,
  ) {
    return _settings.saveWhitelistEntriesForNode(accountId, entries);
  }

  Future<ResolvedUserDirNode?> resolveUserDirNode({
    required String accountId,
    required String? currentNodeId,
  }) async {
    final nodes = await _settings.loadNodes();
    final trimmedNodeId = (currentNodeId ?? '').trim();
    final node = trimmedNodeId.isNotEmpty
        ? nodes.where((n) => n.id == trimmedNodeId).firstOrNull
        : await _settings.loadPreferredNode();
    if (node == null) return null;
    final options = await _settings.loadNodeServerOptions(node.id);
    if (options == null) return null;
    return ResolvedUserDirNode(node: node, options: options);
  }

  Future<void> upsertDirectMessageChat({
    required String accountId,
    required String roomUUID,
    required String serverAddress,
    required String displayName,
    required Uint8List? avatarBytes,
  }) async {
    final repo = _chatStorageGateway.metadataForAccount(accountId);
    final existing = await repo.loadChat(roomUUID, serverAddress: serverAddress);
    final now = DateTime.now();
    AppLogger.i(
      '[HomePersistence] upsertDirectMessageChat room=$roomUUID direct=true '
      'name="$displayName" avatar=${avatarBytes?.length ?? 0}B',
      tag: 'DM',
    );
    await repo.saveChat(
      ChatMetadata(
        uuid: roomUUID,
        name: displayName,
        serverAddress: serverAddress,
        // DM metadata must mirror the contact profile exactly:
        // if the friend has no avatar, clear previously saved room avatar.
        avatarBytes: avatarBytes,
        isDirectMessage: true,
        createdAt: existing?.createdAt ?? now,
        updatedAt: now,
        windowWidth: existing?.windowWidth,
        windowHeight: existing?.windowHeight,
      ),
    );
  }
}
