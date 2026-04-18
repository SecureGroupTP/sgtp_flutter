import 'package:sgtp_flutter/features/contacts/application/models/contacts_models.dart';
import 'package:sgtp_flutter/features/contacts/domain/repositories/i_user_dir_client.dart';
import 'package:sgtp_flutter/features/settings/application/services/settings_management_service.dart';
import 'package:sgtp_flutter/features/setup/domain/entities/contact_directory_models.dart';

class ContactsDirectoryService {
  ContactsDirectoryService({
    required SettingsManagementService settingsManagementService,
  }) : _settings = settingsManagementService;

  final SettingsManagementService _settings;

  Future<void> saveContactEntries({
    required String accountId,
    required List<ContactEntry> entries,
  }) {
    return _settings.saveContactEntriesForNode(accountId, entries);
  }

  /// Searches for an exact username match on the server.
  ///
  /// [client] must be the already-connected and authenticated [IUserDirClient]
  /// from the active session — it is NOT closed after the call.
  Future<ContactsServerSearchHit?> searchExactUser({
    required IUserDirClient? client,
    required String normalizedUsername,
    required List<ContactEntry> existingEntries,
  }) async {
    if (client == null) return null;

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
  }
}

