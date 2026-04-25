import 'dart:typed_data';

import 'package:sgtp_flutter/core/sgtp_server_options.dart';
import 'package:sgtp_flutter/features/messaging/domain/entities/sgtp_config.dart';
import 'package:sgtp_flutter/features/notifications/domain/entities/linux_notification_settings.dart';
import 'package:sgtp_flutter/features/settings/application/models/settings_models.dart';

class SettingsBootstrapData {
  const SettingsBootstrapData({
    required this.nodes,
    required this.accountIds,
    required this.preferredNodeId,
    required this.preferredAccountId,
    required this.lastAddress,
    required this.mediaSettings,
    required this.uiSettings,
    required this.linuxNotificationSettings,
  });

  final List<NodeConfig> nodes;
  final List<String> accountIds;
  final String? preferredNodeId;
  final String? preferredAccountId;
  final String? lastAddress;
  final MediaTransferSettings mediaSettings;
  final UiInteractionSettings uiSettings;
  final LinuxNotificationSettings linuxNotificationSettings;
}

class SettingsAccountSnapshot {
  const SettingsAccountSnapshot({
    required this.nickname,
    required this.username,
    required this.avatar,
    required this.deviceId,
    required this.privateKeyBytes,
    required this.privateKeyName,
    required this.publicKey,
    required this.contactEntries,
  });

  final String nickname;
  final String username;
  final Uint8List? avatar;
  final String deviceId;
  final Uint8List? privateKeyBytes;
  final String? privateKeyName;
  final Uint8List? publicKey;
  final List<ContactEntry> contactEntries;
}

class SettingsPrivateKeyData {
  const SettingsPrivateKeyData({
    required this.bytes,
    required this.name,
    required this.publicKey,
  });

  final Uint8List bytes;
  final String name;
  final Uint8List publicKey;

  String get text => String.fromCharCodes(bytes).trim();
}

class SettingsProfilesCache {
  const SettingsProfilesCache({
    required this.avatarsByAccountId,
    required this.nicknamesByAccountId,
  });

  final Map<String, Uint8List?> avatarsByAccountId;
  final Map<String, String> nicknamesByAccountId;
}

class SettingsRegistryState {
  const SettingsRegistryState({
    required this.nodes,
    required this.accountIds,
    required this.preferredNodeId,
    required this.preferredAccountId,
  });

  final List<NodeConfig> nodes;
  final List<String> accountIds;
  final String? preferredNodeId;
  final String? preferredAccountId;
}

class SettingsAppliedConfig {
  const SettingsAppliedConfig({
    required this.accountId,
    required this.serverAddress,
    required this.config,
    required this.deviceId,
    required this.nicknames,
    required this.contactEntries,
  });

  final String accountId;
  final String serverAddress;
  final SgtpConfig config;
  final String deviceId;
  final Map<String, String> nicknames;
  final List<ContactEntry> contactEntries;
}

class SettingsNodeServerOptionsState {
  const SettingsNodeServerOptionsState({
    required this.options,
    required this.savedAt,
  });

  final SgtpServerOptions? options;
  final DateTime? savedAt;
}

