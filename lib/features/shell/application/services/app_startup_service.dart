import 'dart:typed_data';

import 'package:sgtp_flutter/core/crypto/ed25519_utils.dart';
import 'package:sgtp_flutter/core/openssh_parser.dart';
import 'package:sgtp_flutter/core/sgtp_transport.dart';
import 'package:sgtp_flutter/core/uuid_v7.dart';
import 'package:sgtp_flutter/features/messaging/domain/entities/sgtp_config.dart';
import 'package:sgtp_flutter/features/settings/application/services/settings_management_service.dart';
import 'package:sgtp_flutter/features/setup/domain/entities/contact_directory_models.dart';
import 'package:sgtp_flutter/features/shell/application/models/app_startup_result.dart';

class AppStartupService {
  AppStartupService({
    required SettingsManagementService settingsManagementService,
  }) : _settings = settingsManagementService;

  final SettingsManagementService _settings;

  Future<AppStartupResult> resolve() async {
    final lastAddr = await _settings.getLastAddress() ?? '';
    var accountId = ((await _settings.loadLastAccountId()) ?? '').trim();
    final preferredNode = await _settings.loadPreferredNode();
    final allNodes = await _settings.loadNodes();

    if (accountId.isEmpty && preferredNode != null) {
      final fromNode = preferredNode.effectiveAccountId.trim();
      if (fromNode.isNotEmpty) {
        accountId = fromNode;
        await _settings.setLastAccountId(accountId);
      }
    }
    if (accountId.isEmpty) {
      final all = await _settings.loadAccountIds();
      if (all.isNotEmpty) {
        accountId = all.first;
        await _settings.setLastAccountId(accountId);
      }
    }

    final nickname = accountId.isEmpty
        ? ''
        : await _settings.loadUserNicknameForNode(accountId);
    final hasServerConfigured = preferredNode != null || allNodes.isNotEmpty;
    final hasProfileConfigured =
        accountId.isNotEmpty && nickname.trim().isNotEmpty;
    if (!hasServerConfigured || !hasProfileConfigured) {
      return const AppStartupResult.showOnboarding();
    }

    if (accountId.isEmpty) {
      accountId = uuidBytesToHex(generateUUIDv7());
      await _settings.upsertAccountId(accountId);
      await _settings.saveUserNicknameForNode(accountId, 'Account');
      await _settings.setLastAccountId(accountId);
    }

    final chatServer = preferredNode?.chatAddress ??
        (lastAddr.isEmpty ? 'localhost:443' : lastAddr);
    final discoveryServer = preferredNode?.discoveryAddress ??
        (lastAddr.isEmpty ? 'localhost:443' : lastAddr);

    if (accountId.trim().isNotEmpty) {
      await _settings.migrateLegacyAccountDataToNodeIfNeeded(accountId);
    }

    var savedKey = await _settings.loadPrivateKeyForNode(accountId);
    savedKey ??= await _settings.loadPrivateKey();
    if (savedKey == null) {
      try {
        final generated =
            await _settings.generatePrivateKey(accountId: accountId);
        savedKey = (bytes: generated.bytes, name: generated.name);
      } catch (_) {
        return const AppStartupResult.retry();
      }
    }

    try {
      final parsed = parseOpenSshPrivateKey(savedKey.bytes);
      final keyPair = makeKeyPair(parsed.seed, parsed.publicKey);
      final mediaSettings = await _settings.loadMediaTransferSettings();
      final deviceId = await _settings.loadOrCreateDeviceIdForNode(accountId);

      final entries = accountId.trim().isEmpty
          ? await _settings.loadContactEntries()
          : await _settings.loadContactEntriesForNode(accountId);
      final selfHex = parsed.publicKey
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
      final seen = <String>{};
      final sanitizedEntries = <ContactEntry>[];
      for (final entry in entries) {
        final hex = entry.hexKey.toLowerCase();
        if (hex == selfHex) continue;
        if (!seen.add(hex)) continue;
        sanitizedEntries.add(entry);
      }
      final nicknames = {for (final e in sanitizedEntries) e.hexKey: e.name};
      final userAvatar = accountId.trim().isEmpty
          ? await _settings.loadUserAvatar()
          : await _settings.loadUserAvatarForNode(accountId);

      return AppStartupResult.openHome(
        HomeLaunchData(
          accountId: accountId,
          config: SgtpConfig(
            accountId: accountId,
            deviceId: deviceId,
            serverAddr: chatServer,
            discoveryPort: preferredNode?.effectiveDiscoveryPort,
            roomUUID: Uint8List(16),
            identityKeyPair: keyPair,
            myPublicKey: parsed.publicKey,
            transport: preferredNode?.transport ?? SgtpTransportFamily.tcp,
            useTls: preferredNode?.useTls ?? false,
            fakeSni: preferredNode?.fakeSni ?? '',
            nodeId: preferredNode?.id,
            mediaChunkSizeBytes: mediaSettings.mediaChunkSizeBytes,
          ),
          nicknames: nicknames,
          serverAddress: discoveryServer,
          userAvatar: userAvatar,
          initialContacts: sanitizedEntries,
        ),
      );
    } catch (_) {
      if (accountId.trim().isNotEmpty) {
        await _settings.clearPrivateKeyForNode(accountId);
      } else {
        await _settings.clearPrivateKey();
      }
      return const AppStartupResult.retry();
    }
  }
}

