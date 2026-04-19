import 'dart:convert' show ascii, base64;
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'package:sgtp_flutter/core/app_log.dart';
import 'package:sgtp_flutter/core/crypto/ed25519_utils.dart';
import 'package:sgtp_flutter/core/openssh_parser.dart';
import 'package:sgtp_flutter/core/qr_data.dart';
import 'package:sgtp_flutter/core/sgtp_server_options.dart';
import 'package:sgtp_flutter/core/sgtp_transport.dart';
import 'package:sgtp_flutter/core/uuid_v7.dart';
import 'package:sgtp_flutter/features/contacts/domain/repositories/i_user_dir_client.dart';
import 'package:sgtp_flutter/features/messaging/data/transport/server_discovery.dart';
import 'package:sgtp_flutter/features/messaging/domain/entities/sgtp_config.dart';
import 'package:sgtp_flutter/features/setup/data/repositories/app_backup_repository.dart';
import 'package:sgtp_flutter/features/setup/data/repositories/settings_repository.dart';
import 'package:sgtp_flutter/features/settings/application/models/settings_management_models.dart';
import 'package:sgtp_flutter/features/setup/domain/entities/contact_directory_models.dart';
import 'package:sgtp_flutter/features/setup/domain/entities/node.dart';

final _log = AppLog('SettingsManagementService');

class SettingsManagementService {
  SettingsManagementService({
    required SettingsRepository settingsRepository,
    required AppBackupRepository appBackupRepository,
    required UserDirClientFactory userDirClientFactory,
  })  : _settings = settingsRepository,
        _backups = appBackupRepository,
        _userDirClientFactory = userDirClientFactory;

  final SettingsRepository _settings;
  final AppBackupRepository _backups;
  final UserDirClientFactory _userDirClientFactory;

  Future<List<NodeConfig>> loadNodes() => _settings.loadNodes();
  Future<List<String>> loadAccountIds() => _settings.loadAccountIds();
  Future<NodeConfig?> loadPreferredNode() => _settings.loadPreferredNode();
  Future<String?> loadLastAccountId() => _settings.loadLastAccountId();
  Future<String?> getLastAddress() => _settings.getLastAddress();
  Future<void> migrateLegacyAccountDataToNodeIfNeeded(String accountId) =>
      _settings.migrateLegacyAccountDataToNodeIfNeeded(accountId);
  Future<MediaTransferSettings> loadMediaTransferSettings() =>
      _settings.loadMediaTransferSettings();
  Future<UiInteractionSettings> loadUiInteractionSettings() =>
      _settings.loadUiInteractionSettings();
  Future<String> loadUserNicknameForNode(String accountId) =>
      _settings.loadUserNicknameForNode(accountId);
  Future<String> loadOrCreateDeviceIdForNode(String accountId) =>
      _settings.loadOrCreateDeviceIdForNode(accountId);
  Future<String> loadUserUsernameForNode(String accountId) =>
      _settings.loadUserUsernameForNode(accountId);
  Future<Uint8List?> loadUserAvatarForNode(String accountId) =>
      _settings.loadUserAvatarForNode(accountId);
  Future<({Uint8List bytes, String name})?> loadPrivateKeyForNode(
    String accountId,
  ) =>
      _settings.loadPrivateKeyForNode(accountId);
  Future<List<ContactEntry>> loadContactEntriesForNode(String accountId) =>
      _settings.loadContactEntriesForNode(accountId);
  Future<String?> loadPreferredMicrophoneForNode(String accountId) =>
      _settings.loadPreferredMicrophoneForNode(accountId);
  Future<String?> loadPreferredCameraForNode(String accountId) =>
      _settings.loadPreferredCameraForNode(accountId);
  Future<void> savePreferredMicrophoneForNode(String accountId, String? id) =>
      _settings.savePreferredMicrophoneForNode(accountId, id);
  Future<void> savePreferredCameraForNode(String accountId, String? name) =>
      _settings.savePreferredCameraForNode(accountId, name);
  Future<void> savePrivateKeyForNode(
    String accountId,
    Uint8List bytes,
    String name,
  ) =>
      _settings.savePrivateKeyForNode(accountId, bytes, name);
  Future<void> saveContactEntriesForNode(
    String accountId,
    List<ContactEntry> entries,
  ) =>
      _settings.saveContactEntriesForNode(accountId, entries);
  Future<void> saveUserAvatarForNode(String accountId, Uint8List bytes) =>
      _settings.saveUserAvatarForNode(accountId, bytes);
  Future<void> clearUserAvatarForNode(String accountId) =>
      _settings.clearUserAvatarForNode(accountId);
  Future<void> setLastNodeId(String nodeId) => _settings.setLastNodeId(nodeId);
  Future<void> setLastAccountId(String accountId) =>
      _settings.setLastAccountId(accountId);
  Future<void> upsertNode(NodeConfig node) => _settings.upsertNode(node);
  Future<void> clearPrivateKeyForNode(String accountId) =>
      _settings.clearPrivateKeyForNode(accountId);
  Future<void> clearDeviceIdForNode(String accountId) =>
      _settings.clearDeviceIdForNode(accountId);
  Future<void> clearContactEntriesForNode(String accountId) =>
      _settings.clearContactEntriesForNode(accountId);
  Future<void> saveUserNicknameForNode(String accountId, String nickname) =>
      _settings.saveUserNicknameForNode(accountId, nickname);
  Future<void> saveUserUsernameForNode(String accountId, String username) =>
      _settings.saveUserUsernameForNode(accountId, username);
  Future<void> deleteAccountId(String accountId) =>
      _settings.deleteAccountId(accountId);
  Future<void> saveNodeServerOptions(
    String nodeId,
    SgtpServerOptions options,
  ) async {}
  Future<SgtpServerOptions?> loadNodeServerOptions(String nodeId) async {
    final id = nodeId.trim();
    if (id.isEmpty) return null;
    final nodes = await _settings.loadNodes();
    final node = nodes.where((n) => n.id == id).firstOrNull;
    if (node == null) return null;
    try {
      final normalizedHost = normalizeNodeHost(node.host);
      if (normalizedHost.isEmpty) return null;
      final parsed = parseHostPort(normalizedHost);
      final result = await SgtpServerDiscovery.discover(
        parsed?.$1 ?? normalizedHost,
        preferredPort: node.effectiveDiscoveryPort ?? parsed?.$2,
      );
      return result.opts;
    } catch (_) {
      return null;
    }
  }

  Future<DateTime?> loadNodeServerOptionsSavedAt(String nodeId) async => null;
  Future<void> saveNodeEditorAdvancedExpanded(bool expanded) =>
      _settings.saveNodeEditorAdvancedExpanded(expanded);
  Future<bool> loadNodeEditorAdvancedExpanded() =>
      _settings.loadNodeEditorAdvancedExpanded();
  Future<void> upsertAccountId(String accountId) =>
      _settings.upsertAccountId(accountId);
  Future<void> deleteNode(String nodeId) => _settings.deleteNode(nodeId);
  Future<void> saveMediaTransferSettings(MediaTransferSettings settings) =>
      _settings.saveMediaTransferSettings(settings);
  Future<void> savePingIntervalSeconds(int seconds) =>
      _settings.savePingIntervalSeconds(seconds);
  Future<void> clearAllLocalData() => _settings.clearAllLocalData();
  Future<void> saveAddress(String address) => _settings.saveAddress(address);
  Future<({Uint8List bytes, String name})?> loadPrivateKey() =>
      _settings.loadPrivateKey();
  Future<QrStyleSettings> loadQrStyleSettings() =>
      _settings.loadQrStyleSettings();
  Future<void> saveQrStyleSettings(QrStyleSettings settings) =>
      _settings.saveQrStyleSettings(settings);
  Future<double?> loadChatScrollPosition(String accountId, String roomUUID) =>
      _settings.loadChatScrollPosition(accountId, roomUUID);
  Future<void> saveChatScrollPosition(
    String accountId,
    String roomUUID,
    double offset,
  ) =>
      _settings.saveChatScrollPosition(accountId, roomUUID, offset);
  Future<void> clearPrivateKey() => _settings.clearPrivateKey();
  Future<List<ContactEntry>> loadContactEntries() =>
      _settings.loadContactEntries();
  Future<Uint8List?> loadUserAvatar() => _settings.loadUserAvatar();
  Future<Map<String, FriendStateRecord>> loadFriendStates(String accountId) =>
      _settings.loadFriendStates(accountId);
  Future<void> saveFriendStates(
    String accountId,
    Map<String, FriendStateRecord> friendStates,
  ) =>
      _settings.saveFriendStates(accountId, friendStates);
  Future<Set<String>> loadSuppressedContacts(String accountId) =>
      _settings.loadSuppressedContacts(accountId);
  Future<void> saveSuppressedContacts(
    String accountId,
    Set<String> suppressedContacts,
  ) =>
      _settings.saveSuppressedContacts(accountId, suppressedContacts);
  Future<void> saveContactProfile(String accountId, ContactProfile profile) =>
      _settings.saveContactProfile(accountId, profile);
  Future<ContactProfile?> loadContactProfile(
    String accountId,
    String pubkeyHex,
  ) =>
      _settings.loadContactProfile(accountId, pubkeyHex);
  Future<Map<String, ContactProfile>> loadAllContactProfiles(
    String accountId,
  ) =>
      _settings.loadAllContactProfiles(accountId);

  Future<BackupExportData> createBackup() => _backups.createBackup();
  Future<BackupRestoreSummary> restoreFromBytes(
    Uint8List bytes, {
    bool merge = true,
  }) =>
      _backups.restoreFromBytes(bytes, merge: merge);

  Future<SettingsBootstrapData> loadBootstrapData() async {
    final nodes = await _settings.loadNodes();
    final accountIds = await _settings.loadAccountIds();
    final preferredNode = await _settings.loadPreferredNode();
    final savedAccountId = await _settings.loadLastAccountId();
    final preferredAccountId =
        (savedAccountId != null && accountIds.contains(savedAccountId))
            ? savedAccountId
            : (accountIds.isNotEmpty ? accountIds.first : null);
    if (preferredAccountId != null && preferredAccountId.trim().isNotEmpty) {
      await _settings
          .migrateLegacyAccountDataToNodeIfNeeded(preferredAccountId);
    }

    return SettingsBootstrapData(
      nodes: nodes,
      accountIds: accountIds,
      preferredNodeId:
          preferredNode?.id ?? (nodes.isNotEmpty ? nodes.first.id : null),
      preferredAccountId: preferredAccountId,
      lastAddress: await _settings.getLastAddress(),
      mediaSettings: await _settings.loadMediaTransferSettings(),
      uiSettings: await _settings.loadUiInteractionSettings(),
    );
  }

  Future<SettingsAccountSnapshot> loadAccountSnapshot(String accountId) async {
    final nickname = await _settings.loadUserNicknameForNode(accountId);
    final username = await _settings.loadUserUsernameForNode(accountId);
    final avatar = await _settings.loadUserAvatarForNode(accountId);
    final deviceId = await _settings.loadOrCreateDeviceIdForNode(accountId);
    final savedKey = await _settings.loadPrivateKeyForNode(accountId);

    Uint8List? privateKeyBytes;
    String? privateKeyName;
    Uint8List? publicKey;
    if (savedKey != null) {
      try {
        final parsed = parseOpenSshPrivateKey(savedKey.bytes);
        privateKeyBytes = savedKey.bytes;
        privateKeyName = savedKey.name;
        publicKey = parsed.publicKey;
      } catch (_) {}
    }

    return SettingsAccountSnapshot(
      nickname: nickname,
      username: username,
      avatar: avatar,
      deviceId: deviceId,
      privateKeyBytes: privateKeyBytes,
      privateKeyName: privateKeyName,
      publicKey: publicKey,
      contactEntries: await _settings.loadContactEntriesForNode(accountId),
    );
  }

  Future<SettingsProfilesCache> loadProfilesCache(
      List<String> accountIds) async {
    final avatars = <String, Uint8List?>{};
    final nicknames = <String, String>{};
    for (final accountId in accountIds) {
      avatars[accountId] = await _settings.loadUserAvatarForNode(accountId);
      nicknames[accountId] = await _settings.loadUserNicknameForNode(accountId);
    }
    return SettingsProfilesCache(
      avatarsByAccountId: avatars,
      nicknamesByAccountId: nicknames,
    );
  }

  Future<SettingsRegistryState> reloadRegistryState() async {
    final nodes = await _settings.loadNodes();
    final accountIds = await _settings.loadAccountIds();
    final preferred = await _settings.loadPreferredNode();
    final savedAccountId = await _settings.loadLastAccountId();
    final preferredAccountId =
        (savedAccountId != null && accountIds.contains(savedAccountId))
            ? savedAccountId
            : (accountIds.isNotEmpty ? accountIds.first : null);
    return SettingsRegistryState(
      nodes: nodes,
      accountIds: accountIds,
      preferredNodeId:
          preferred?.id ?? (nodes.isNotEmpty ? nodes.first.id : null),
      preferredAccountId: preferredAccountId,
    );
  }

  Future<void> deleteAccount(String accountId) async {
    final linkedServers = (await _settings.loadNodes())
        .where((node) => node.accountId.trim() == accountId.trim());
    for (final node in linkedServers) {
      await _settings.upsertNode(node.copyWith(accountId: ''));
    }
    await _settings.clearPrivateKeyForNode(accountId);
    await _settings.clearDeviceIdForNode(accountId);
    await _settings.clearContactEntriesForNode(accountId);
    await _settings.clearUserAvatarForNode(accountId);
    await _settings.saveUserNicknameForNode(accountId, '');
    await _settings.saveUserUsernameForNode(accountId, '');
    await _settings.deleteAccountStorage(accountId);
    await _settings.deleteAccountId(accountId);
  }

  Future<void> addEmptyAccount(String accountId) async {
    await _settings.upsertAccountId(accountId);
    await _settings.loadOrCreateDeviceIdForNode(accountId);
    await _settings.saveUserNicknameForNode(accountId, 'Account');
    await _settings.setLastAccountId(accountId);
  }

  Future<String?> registerProfileOnUserDir({
    required String accountId,
    required NodeConfig node,
    required SgtpServerOptions options,
    required Uint8List privateKeyBytes,
    required String nickname,
    required String username,
    Uint8List? avatarBytes,
  }) async {
    try {
      final parsed = parseOpenSshPrivateKey(privateKeyBytes);
      final keyPair = makeKeyPair(parsed.seed, parsed.publicKey);
      final normalizedUsername = _normalizeUsername(username);
      final wireUsername =
          normalizedUsername == null ? '' : '@$normalizedUsername';
      final deviceId = await _settings.loadOrCreateDeviceIdForNode(accountId);

      final client = _userDirClientFactory(node, options);
      if (client == null) {
        return 'User directory is not available on this server';
      }
      try {
        await client.connect();
        final result = await client.registerWithResult(
          username: wireUsername,
          fullname: nickname.trim(),
          pubkey: parsed.publicKey,
          avatarBytes: avatarBytes ?? Uint8List(0),
          identityKeyPair: keyPair,
          deviceId: deviceId,
        );
        if (result.ok) return null;
        final msg = (result.errorMessage ?? '').trim();
        final lower = msg.toLowerCase();
        if (lower.contains('taken') ||
            lower.contains('exists') ||
            lower.contains('occupied') ||
            lower.contains('already')) {
          return 'Username already taken';
        }
        if (msg.isNotEmpty) return msg;
        return 'Profile registration failed';
      } finally {
        client.close();
      }
    } catch (e) {
      return 'Profile registration failed: $e';
    }
  }

  String? _normalizeUsername(String raw) {
    final stripped = raw.trim().replaceFirst(RegExp(r'^@+'), '');
    final sanitized = stripped
        .replaceAll(RegExp(r'[^A-Za-z0-9_]'), '')
        .substring(
          0,
          stripped.replaceAll(RegExp(r'[^A-Za-z0-9_]'), '').length.clamp(0, 32),
        );
    if (sanitized.isEmpty) return null;
    return sanitized;
  }

  Future<void> saveDetachedNode(NodeConfig node) {
    return _settings.upsertNode(node.copyWith(accountId: ''));
  }

  Future<SettingsPrivateKeyData> importPrivateKey({
    required String accountId,
    required Uint8List bytes,
    required String name,
  }) async {
    final parsed = parseOpenSshPrivateKey(bytes);
    await _settings.savePrivateKeyForNode(accountId, bytes, name);
    return SettingsPrivateKeyData(
      bytes: bytes,
      name: name,
      publicKey: parsed.publicKey,
    );
  }

  Future<SettingsPrivateKeyData> importPrivateKeyFromText({
    required String accountId,
    required String text,
    required String name,
  }) {
    return importPrivateKey(
      accountId: accountId,
      bytes: Uint8List.fromList(text.codeUnits),
      name: name,
    );
  }

  Future<SettingsPrivateKeyData> generatePrivateKey({
    required String accountId,
    String name = 'identity',
  }) async {
    final algorithm = Ed25519();
    final keyPair = await algorithm.newKeyPair();
    final pubKey = await keyPair.extractPublicKey();
    final privBytes = await keyPair.extractPrivateKeyBytes();
    final pubBytes = Uint8List.fromList(pubKey.bytes);
    final opensshBytes = _encodeOpenSshPrivateKey(privBytes, pubBytes);
    await _settings.savePrivateKeyForNode(accountId, opensshBytes, name);
    return SettingsPrivateKeyData(
      bytes: opensshBytes,
      name: name,
      publicKey: pubBytes,
    );
  }

  Future<bool> hasPrivateKey(String accountId) async {
    return await _settings.loadPrivateKeyForNode(accountId) != null;
  }

  Future<List<ContactEntry>> importContactEntriesFromPublicKeyFiles({
    required List<({Uint8List bytes, String name})> files,
  }) async {
    final entries = <ContactEntry>[];
    for (final file in files) {
      final pubKey = tryParsePublicKeyFile(file.bytes);
      if (pubKey == null) continue;
      var name = file.name;
      if (name.toLowerCase().endsWith('.pub')) {
        name = name.substring(0, name.length - 4);
      }
      entries.add(ContactEntry(bytes: pubKey, name: name));
    }
    return entries;
  }

  Future<List<ContactEntry>> mergeContactEntries({
    required String accountId,
    required List<ContactEntry> currentEntries,
    required List<ContactEntry> newEntries,
  }) async {
    final combined = [...currentEntries];
    for (final entry in newEntries) {
      if (!combined.any((item) => item.hexKey == entry.hexKey)) {
        combined.add(entry);
      }
    }
    await _settings.saveContactEntriesForNode(accountId, combined);
    return combined;
  }

  Future<List<ContactEntry>> addContactEntry({
    required String accountId,
    required List<ContactEntry> currentEntries,
    required ContactEntry entry,
  }) async {
    final exists = currentEntries.any((item) => item.hexKey == entry.hexKey);
    if (exists) {
      throw const FormatException('Key already in contacts');
    }
    final updated = [...currentEntries, entry];
    await _settings.saveContactEntriesForNode(accountId, updated);
    return updated;
  }

  Future<List<ContactEntry>> renameContactEntry({
    required String accountId,
    required List<ContactEntry> currentEntries,
    required int index,
    required String newName,
  }) async {
    final updated = List<ContactEntry>.from(currentEntries);
    updated[index] = updated[index].copyWithName(newName);
    await _settings.saveContactEntriesForNode(accountId, updated);
    return updated;
  }

  Future<List<ContactEntry>> removeContactEntry({
    required String accountId,
    required List<ContactEntry> currentEntries,
    required int index,
  }) async {
    final updated = List<ContactEntry>.from(currentEntries)..removeAt(index);
    await _settings.saveContactEntriesForNode(accountId, updated);
    return updated;
  }

  Future<Uint8List> saveUserAvatar({
    required String accountId,
    required Uint8List bytes,
  }) async {
    await _settings.saveUserAvatarForNode(accountId, bytes);
    return bytes;
  }

  Future<void> clearUserAvatar(String accountId) {
    return _settings.clearUserAvatarForNode(accountId);
  }

  Future<SettingsNodeServerOptionsState> loadNodeServerOptionsState(
    String nodeId,
  ) async {
    final options = await _settings.loadNodeServerOptions(nodeId);
    final savedAt = await _settings.loadNodeServerOptionsSavedAt(nodeId);
    return SettingsNodeServerOptionsState(options: options, savedAt: savedAt);
  }

  NodeConfig? selectPreferredServer({
    required List<NodeConfig> nodes,
    required String? preferredNodeId,
  }) {
    final id = (preferredNodeId ?? '').trim();
    if (id.isNotEmpty) {
      for (final node in nodes) {
        if (node.id == id) return node;
      }
    }
    return nodes.isNotEmpty ? nodes.first : null;
  }

  String effectiveServerAddress({
    required List<NodeConfig> nodes,
    required String? preferredNodeId,
    required String standaloneServerAddress,
  }) {
    final active = selectPreferredServer(
      nodes: nodes,
      preferredNodeId: preferredNodeId,
    );
    if (active != null) return active.chatAddress;
    final normalized = standaloneServerAddress
        .trim()
        .replaceAll(RegExp(r'^https?://', caseSensitive: false), '')
        .replaceAll(RegExp(r'^wss?://', caseSensitive: false), '')
        .trim();
    return normalized.isEmpty ? 'localhost:443' : normalized;
  }

  SettingsAppliedConfig buildAppliedConfig({
    required String accountId,
    required String deviceId,
    required Uint8List privateKeyBytes,
    required String username,
    Uint8List? userAvatarBytes,
    required List<NodeConfig> nodes,
    required String? preferredNodeId,
    required String standaloneServerAddress,
    required List<ContactEntry> contactEntries,
    required int pingIntervalSeconds,
    required int mediaChunkSizeBytes,
  }) {
    final node = selectPreferredServer(
      nodes: nodes,
      preferredNodeId: preferredNodeId,
    );
    if (node == null) {
      throw const FormatException('No server selected');
    }
    final parsed = parseOpenSshPrivateKey(privateKeyBytes);
    final keyPair = makeKeyPair(parsed.seed, parsed.publicKey);
    final serverAddress = effectiveServerAddress(
      nodes: nodes,
      preferredNodeId: preferredNodeId,
      standaloneServerAddress: standaloneServerAddress,
    );
    final nicknames = {
      for (final entry in contactEntries) entry.hexKey: entry.name,
    };
    return SettingsAppliedConfig(
      accountId: accountId,
      serverAddress: serverAddress,
      deviceId: deviceId,
      config: SgtpConfig(
        accountId: accountId,
        deviceId: deviceId,
        serverAddr: serverAddress,
        discoveryPort: node.effectiveDiscoveryPort,
        roomUUID: Uint8List(16),
        identityKeyPair: keyPair,
        myPublicKey: parsed.publicKey,
        transport: node.transport,
        useTls: node.useTls,
        fakeSni: node.fakeSni,
        nodeId: node.id,
        userUsername: username.trim().isEmpty ? null : username.trim(),
        userAvatarBytes: userAvatarBytes,
        pingIntervalSeconds: pingIntervalSeconds,
        mediaChunkSizeBytes: mediaChunkSizeBytes,
      ),
      nicknames: nicknames,
      contactEntries: contactEntries,
    );
  }

  Future<void> discoverNodeAndCache(NodeConfig node) async {
    final (:opts, :port, :tls) = await SgtpServerDiscovery.discover(
      node.host,
      preferredPort: node.effectiveDiscoveryPort,
      preferredTls: node.useTls,
    );
    final labels = [
      if (opts.tcp) 'TCP:${opts.tcpPort}',
      if (opts.tcpTls) 'TCP+TLS:${opts.tcpTlsPort}',
      if (opts.http) 'HTTP:${opts.httpPort}',
      if (opts.httpTls) 'HTTP+TLS:${opts.httpTlsPort}',
      if (opts.websocket) 'WebSocket:${opts.websocketPort}',
      if (opts.websocketTls) 'WebSocket+TLS:${opts.websocketTlsPort}',
    ];
    _log.info('Discovery [{nodeName}] {host} via {scheme}:{port}: {labels}', parameters: {'nodeName': node.name, 'host': node.host, 'scheme': tls ? 'https' : 'http', 'port': port, 'labels': labels.join(', ')});
  }

  Future<void> logCachedDiscovery(List<NodeConfig> nodes) async {
    if (nodes.isEmpty) {
      _log.info('Discovery: no accounts configured');
      return;
    }
    _log.info('Discovery cache is disabled; using live discovery');
  }

  String normalizeNodeHost(String raw) => raw
      .trim()
      .replaceAll(RegExp(r'^https?://', caseSensitive: false), '')
      .replaceAll(RegExp(r'^wss?://', caseSensitive: false), '')
      .trim();

  Future<SettingsNodeServerOptionsState> refreshNodeServerOptions({
    required String nodeId,
    required String host,
  }) async {
    final normalizedHost = normalizeNodeHost(host);
    if (normalizedHost.isEmpty) {
      throw const FormatException('Host is empty');
    }

    final parsed = parseHostPort(normalizedHost);
    final (:opts, :port, :tls) = await SgtpServerDiscovery.discover(
      parsed?.$1 ?? normalizedHost,
      preferredPort: parsed?.$2,
    );
    final savedAt = DateTime.now();
    final labels = [
      if (opts.tcp) 'TCP:${opts.tcpPort}',
      if (opts.tcpTls) 'TCP+TLS:${opts.tcpTlsPort}',
      if (opts.http) 'HTTP:${opts.httpPort}',
      if (opts.httpTls) 'HTTP+TLS:${opts.httpTlsPort}',
      if (opts.websocket) 'WebSocket:${opts.websocketPort}',
      if (opts.websocketTls) 'WebSocket+TLS:${opts.websocketTlsPort}',
    ];
    _log.info('Discovery [{nodeId}] {host} via {scheme}:{port}: {labels}', parameters: {'nodeId': nodeId, 'host': normalizedHost, 'scheme': tls ? 'https' : 'http', 'port': port, 'labels': labels.join(', ')});
    return SettingsNodeServerOptionsState(options: opts, savedAt: savedAt);
  }

  Future<({SgtpServerOptions opts, int port, bool tls})> discoverServer(
    String host, {
    int? preferredPort,
    bool? preferredTls,
  }) =>
      SgtpServerDiscovery.discover(
        host,
        preferredPort: preferredPort,
        preferredTls: preferredTls,
      );

  (String, int?)? parseHostPort(String raw) {
    final normalized = normalizeNodeHost(raw);
    if (normalized.isEmpty) return null;

    if (normalized.startsWith('[')) {
      final end = normalized.indexOf(']');
      if (end <= 1) return null;
      final host = normalized.substring(1, end).trim();
      if (host.isEmpty) return null;
      final rest = normalized.substring(end + 1).trim();
      if (rest.isEmpty) return (host, null);
      if (!rest.startsWith(':')) return null;
      final port = int.tryParse(rest.substring(1).trim());
      if (port == null) return null;
      return (host, port);
    }

    final idx = normalized.lastIndexOf(':');
    if (idx <= 0 || idx == normalized.length - 1) return (normalized, null);
    final host = normalized.substring(0, idx).trim();
    final port = int.tryParse(normalized.substring(idx + 1).trim());
    if (port == null) return null;
    return (host, port);
  }

  NodeConfig? importNodeFromShareData(QrShareData data) {
    if (data.type != 'node') return null;

    bool validPort(int? port) => port != null && port > 0 && port <= 65535;

    final id = (data.nodeId ?? '').trim().isNotEmpty
        ? data.nodeId!.trim()
        : uuidBytesToHex(generateUUIDv7());

    String? host =
        data.nodeHost != null ? normalizeNodeHost(data.nodeHost!) : null;
    int? chatPort = data.nodeChatPort;

    if ((host == null || host.isEmpty) && data.serverAddress != null) {
      final parsed = parseHostPort(data.serverAddress!);
      if (parsed != null) {
        host = parsed.$1;
        chatPort ??= parsed.$2;
      }
    }

    host = host?.trim();
    chatPort ??= 443;
    final voicePort = data.nodeVoicePort ?? chatPort;

    if (host == null ||
        host.isEmpty ||
        !validPort(chatPort) ||
        !validPort(voicePort)) {
      return null;
    }

    final name = (data.nodeName ?? host).trim().isEmpty
        ? 'Node'
        : (data.nodeName ?? host).trim();

    return NodeConfig(
      id: id,
      name: name,
      host: host,
      chatPort: chatPort,
      voicePort: voicePort,
      transport: data.nodeTransportFamily ?? SgtpTransportFamily.tcp,
      useTls: data.nodeUseTls ?? false,
    );
  }

  Future<NodeConfig> importDetachedNode(NodeConfig node) async {
    final detached = node.copyWith(accountId: '');
    await _settings.upsertNode(detached);
    return detached;
  }

  Future<NodeConfig?> importDetachedNodeFromInput(String raw) async {
    final parsedShare = QrShareData.parse(raw.trim());
    if (parsedShare != null) {
      final node = importNodeFromShareData(parsedShare);
      if (node == null) return null;
      return importDetachedNode(node);
    }

    final parsedHost = parseHostPort(raw);
    if (parsedHost == null) return null;
    final host = parsedHost.$1;
    final port = parsedHost.$2 ?? 443;
    final node = NodeConfig(
      id: uuidBytesToHex(generateUUIDv7()),
      name: host,
      host: host,
      discoveryPort: port,
      chatPort: port,
      voicePort: port,
    );
    return importDetachedNode(node);
  }

  Uint8List _encodeOpenSshPrivateKey(List<int> seed, Uint8List pubKey) {
    Uint8List packString(List<int> bytes) {
      final b = BytesBuilder();
      final len = bytes.length;
      b.add([
        (len >> 24) & 0xff,
        (len >> 16) & 0xff,
        (len >> 8) & 0xff,
        len & 0xff,
      ]);
      b.add(bytes);
      return b.takeBytes();
    }

    final algo = ascii.encode('ssh-ed25519');
    final pubLine = BytesBuilder()
      ..add(packString(algo))
      ..add(packString(pubKey));
    final publicBlob = pubLine.takeBytes();

    final privBlock = BytesBuilder()
      ..add([0xA5, 0xA5, 0xA5, 0xA5])
      ..add([0xA5, 0xA5, 0xA5, 0xA5])
      ..add(packString(algo))
      ..add(packString(pubKey));
    final privateKey = Uint8List.fromList([...seed, ...pubKey]);
    privBlock.add(packString(privateKey));
    privBlock.add(packString(const <int>[]));
    final rawPriv = privBlock.takeBytes();
    final padLen = (8 - (rawPriv.length % 8)) % 8;
    final paddedPriv = BytesBuilder()
      ..add(rawPriv)
      ..add(List<int>.generate(padLen, (i) => i + 1));

    final b = BytesBuilder()
      ..add(ascii.encode('openssh-key-v1\x00'))
      ..add(packString(ascii.encode('none')))
      ..add(packString(ascii.encode('none')))
      ..add(packString(const <int>[]))
      ..add([0, 0, 0, 1])
      ..add(packString(publicBlob))
      ..add(packString(paddedPriv.takeBytes()));
    final body = b.takeBytes();
    final b64 = base64.encode(body);

    final lines = StringBuffer('-----BEGIN OPENSSH PRIVATE KEY-----\n');
    for (int i = 0; i < b64.length; i += 70) {
      lines.writeln(
        b64.substring(i, i + 70 > b64.length ? b64.length : i + 70),
      );
    }
    lines.write('-----END OPENSSH PRIVATE KEY-----\n');
    return Uint8List.fromList(lines.toString().codeUnits);
  }
}

