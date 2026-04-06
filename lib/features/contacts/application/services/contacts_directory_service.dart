import 'package:sgtp_flutter/features/contacts/application/models/contacts_models.dart';
import 'package:sgtp_flutter/features/contacts/domain/repositories/i_user_dir_client.dart';
import 'package:sgtp_flutter/features/settings/application/services/settings_management_service.dart';
import 'package:sgtp_flutter/features/setup/domain/entities/contact_directory_models.dart';

class ContactsDirectoryService {
  ContactsDirectoryService({
    required SettingsManagementService settingsManagementService,
    required UserDirClientFactory userDirClientFactory,
  })  : _settings = settingsManagementService,
        _clientFactory = userDirClientFactory;

  final SettingsManagementService _settings;
  final UserDirClientFactory _clientFactory;

  Future<void> saveWhitelistEntries({
    required String accountId,
    required List<WhitelistEntry> entries,
  }) {
    return _settings.saveWhitelistEntriesForNode(accountId, entries);
  }

  Future<ContactsServerSearchHit?> searchExactUser({
    required String? serverNodeId,
    required String normalizedUsername,
    required List<WhitelistEntry> existingEntries,
  }) async {
    final client = await _buildUserDirClient(serverNodeId);
    if (client == null) return null;

    try {
      await client.connect();
      final items = await client.search(normalizedUsername, limit: 20);
      final lower = normalizedUsername.toLowerCase();
      final exact = items
          .where((item) => item.username.toLowerCase() == lower)
          .firstOrNull;
      if (exact == null) return null;

      final alreadyTrusted = existingEntries.any(
        (entry) => entry.hexKey.toLowerCase() == exact.pubkeyHex.toLowerCase(),
      );
      if (alreadyTrusted) return null;

      return ContactsServerSearchHit(
        username: exact.username,
        pubkeyHex: exact.pubkeyHex,
        fullname: exact.fullname,
      );
    } finally {
      client.close();
    }
  }

  Future<IUserDirClient?> _buildUserDirClient(String? serverNodeId) async {
    final nodes = await _settings.loadNodes();
    final selectedServerId = (serverNodeId ?? '').trim();
    final node = selectedServerId.isNotEmpty
        ? nodes.where((n) => n.id == selectedServerId).firstOrNull
        : await _settings.loadPreferredNode();
    if (node == null) return null;
    final opts = await _settings.loadNodeServerOptions(node.id);
    if (opts == null) return null;
    return _clientFactory(node, opts);
  }
}
