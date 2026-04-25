import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:sgtp_flutter/core/storage/account_storage_paths.dart';
import 'package:sgtp_flutter/core/storage/local_encryption_service.dart';
import 'package:sgtp_flutter/core/storage/main_database.dart';
import 'package:sgtp_flutter/core/storage/main_database_factory.dart';
import 'package:sgtp_flutter/core/storage/storage_key_service.dart';
import 'package:sgtp_flutter/core/sgtp_server_options.dart';
import 'package:sgtp_flutter/core/uuid_v7.dart';
import 'package:sgtp_flutter/features/setup/domain/entities/contact_directory_models.dart';
import 'package:sgtp_flutter/features/setup/domain/entities/node.dart';

/// Repository for persisting user settings between sessions.
class SettingsRepository {
  factory SettingsRepository({
    AccountStoragePaths? accountStoragePaths,
    StorageKeyService? storageKeyService,
    LocalEncryptionService? localEncryptionService,
    MainDatabaseFactory? mainDatabaseFactory,
  }) {
    final resolvedAccountStoragePaths =
        accountStoragePaths ?? createAccountStoragePaths();
    final resolvedLocalEncryptionService =
        localEncryptionService ?? LocalEncryptionService();
    final resolvedStorageKeyService = storageKeyService ??
        StorageKeyService(
          localEncryptionService: resolvedLocalEncryptionService,
        );
    final resolvedMainDatabaseFactory = mainDatabaseFactory ??
        MainDatabaseFactory(
          accountStoragePaths: resolvedAccountStoragePaths,
          storageKeyService: resolvedStorageKeyService,
        );
    return SettingsRepository._(
      accountStoragePaths: resolvedAccountStoragePaths,
      localEncryptionService: resolvedLocalEncryptionService,
      storageKeyService: resolvedStorageKeyService,
      mainDatabaseFactory: resolvedMainDatabaseFactory,
    );
  }

  SettingsRepository._({
    required AccountStoragePaths accountStoragePaths,
    required LocalEncryptionService localEncryptionService,
    required StorageKeyService storageKeyService,
    required MainDatabaseFactory mainDatabaseFactory,
  })  : _accountStoragePaths = accountStoragePaths,
        _localEncryptionService = localEncryptionService,
        _storageKeyService = storageKeyService,
        _mainDatabaseFactory = mainDatabaseFactory;

  static const _savedAddressesKey = 'sgtp_saved_addresses';
  static const _lastAddressKey = 'sgtp_last_address';
  static const _nodesJsonKey =
      'sgtp_nodes_json_v1'; // [{id,name,host,chatPort,voicePort}]
  static const _lastNodeIdKey = 'sgtp_last_node_id';
  static const _lastAccountIdKey = 'sgtp_last_account_id';
  static const _accountIdsKey = 'sgtp_account_ids_v1';
  static const _accountMarkerKey = 'sgtp_account_marker_v1';
  // Legacy (global) identity + profile keys. New code should prefer per-account scoped variants.
  static const _privKeyB64Key = 'sgtp_private_key_b64';
  static const _privKeyNameKey = 'sgtp_private_key_name';
  static const _contactEntriesJsonKey = 'sgtp_contacts_json'; // [{b64, name}]
  static const _userAvatarB64Key = 'sgtp_user_avatar_b64';
  static const _userNicknameKey = 'sgtp_user_nickname';
  static const _userUsernameKey = 'sgtp_user_username';
  static const _deviceIdKey = 'sgtp_device_id_v1';

  // Per-account scoping / migration
  static const _accountsMigratedV1Key = 'sgtp_accounts_migrated_v1';
  static const _compressFilesKey = 'sgtp_compress_files_enabled';
  static const _compressPhotosKey = 'sgtp_compress_photos_enabled';
  static const _compressVideosKey = 'sgtp_compress_videos_enabled';
  static const _mediaChunkSizeKey = 'sgtp_media_chunk_size_bytes';
  static const _preferredMicIdKey = 'sgtp_preferred_mic_id';
  static const _preferredCameraNameKey = 'sgtp_preferred_camera_name';
  static const _qrPresetIndexKey = 'sgtp_qr_preset_index';
  static const _qrPrimaryColorKey = 'sgtp_qr_primary_color';
  static const _qrSecondaryColorKey = 'sgtp_qr_secondary_color';
  static const _qrShapeStyleKey = 'sgtp_qr_shape_style';
  static const _qrShowLogoKey = 'sgtp_qr_show_logo';
  static const _pingIntervalKey = 'sgtp_ping_interval';
  static const _doubleTapDesktopKey = 'iprefs_doubletap_desktop';
  static const _swipeToReplyKey = 'iprefs_swipe_to_reply';
  static const _longPressMenuKey = 'iprefs_longpress_menu';
  static const _nodeServerOptionsKeyPrefix = 'sgtp_node_server_options_v1_';
  static const _nodeServerOptionsSavedAtKeyPrefix =
      'sgtp_node_server_options_saved_at_v1_';
  static const _nodeEditorAdvancedExpandedKey =
      'sgtp_node_editor_advanced_expanded_v1';
  static const int _maxSaved = 10;

  final AccountStoragePaths _accountStoragePaths;
  final LocalEncryptionService _localEncryptionService;
  final StorageKeyService _storageKeyService;
  final MainDatabaseFactory _mainDatabaseFactory;

  String _scopedKey(String base, String? nodeId) {
    final id = (nodeId ?? '').trim();
    if (id.isEmpty) return base;
    return '${base}_$id';
  }

  Future<MainDatabase> _accountDb(String accountId) {
    final normalized = accountId.trim().isEmpty ? 'default' : accountId.trim();
    return _mainDatabaseFactory.openForAccount(normalized);
  }

  Future<String?> _loadAccountStringSetting(String accountId, String key) async {
    final db = await _accountDb(accountId);
    return db.loadSettingString(key);
  }

  Future<void> _saveAccountStringSetting(
    String accountId,
    String key,
    String value,
  ) async {
    final db = await _accountDb(accountId);
    await db.saveSettingString(key, value);
  }

  Future<Uint8List?> _loadAccountBytesSetting(String accountId, String key) async {
    final db = await _accountDb(accountId);
    return db.loadSettingBytes(key);
  }

  Future<void> _saveAccountBytesSetting(
    String accountId,
    String key,
    Uint8List value,
  ) async {
    final db = await _accountDb(accountId);
    await db.saveSettingBytes(key, value);
  }

  Future<void> _deleteAccountSetting(String accountId, String key) async {
    final db = await _accountDb(accountId);
    await db.deleteSetting(key);
  }

  Future<void> deleteAccountStorage(String accountId) async {
    await _mainDatabaseFactory.deleteAccount(accountId);
    await _storageKeyService.deleteAccountKey(accountId);
    await _localEncryptionService.deleteAccount(accountId);
  }

  // ── Shared sgtp directory ──────────────────────────────────────────────────

  /// Returns (and creates if needed) the fixed SGTP data directory.
  /// On desktop: ~/Documents/sgtp
  /// On mobile:  app documents dir / sgtp
  Future<Directory> getSgtpDirectory() async {
    final docsDir = await getApplicationDocumentsDirectory();
    final dir = Directory('${docsDir.path}/sgtp');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// Deletes all locally persisted SGTP app data:
  /// - SharedPreferences keys for this app
  /// - documents folders used for SGTP files/metadata
  Future<void> clearAllLocalData() async {
    final p = await SharedPreferences.getInstance();
    final accountIds = ((p.getStringList(_accountIdsKey) ?? const <String>[])
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty))
        .toSet()
        .toList(growable: false);
    await p.clear();
    for (final accountId in accountIds) {
      await deleteAccountStorage(accountId);
    }
    await _mainDatabaseFactory.clearAll();
    await _accountStoragePaths.clearAll();
    await _storageKeyService.clearAll();
    await _localEncryptionService.clearAll();

    final docsDir = await getApplicationDocumentsDirectory();
    final folders = <Directory>[
      Directory('${docsDir.path}/sgtp'),
      Directory('${docsDir.path}/sgtp_accounts'),
      Directory('${docsDir.path}/sgtp_chats'),
      Directory('${docsDir.path}/sgtp_media_cache'),
    ];
    for (final dir in folders) {
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    }

    // Remove desktop window state files stored directly in documents root.
    final docsFiles = <File>[
      File('${docsDir.path}/.sgtp_window.json'),
      File('${docsDir.path}/.window_state.json'),
    ];
    for (final file in docsFiles) {
      if (await file.exists()) {
        await file.delete();
      }
    }

    // Best-effort cleanup of temp artifacts created by the app.
    final tmpDir = await getTemporaryDirectory();
    final tempDirs = <Directory>{
      Directory('${tmpDir.path}/sgtp_media_cache'),
      Directory('${Directory.systemTemp.path}/sgtp_media_cache'),
    };
    for (final dir in tempDirs) {
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    }

    // Remove known temporary file patterns used by playback/notifications.
    const tempPrefixes = <String>[
      'sgtp_av_',
      'voice_play_',
      'voice_',
      'vnote_',
      'videonote_',
      'videonote_thumb_',
      'mic_loop_',
    ];
    await _deleteTempFilesByPrefix(tmpDir, tempPrefixes);
    await _deleteTempFilesByPrefix(Directory.systemTemp, tempPrefixes);
  }

  Future<void> _deleteTempFilesByPrefix(
    Directory dir,
    List<String> prefixes,
  ) async {
    if (!await dir.exists()) return;
    await for (final entity in dir.list(recursive: false, followLinks: false)) {
      if (entity is! File) continue;
      final name = _basename(entity.path).toLowerCase();
      final match = prefixes.any((p) => name.startsWith(p));
      if (!match) continue;
      try {
        await entity.delete();
      } catch (_) {}
    }
  }

  String _basename(String path) {
    final normalized = path.replaceAll('\\', '/');
    final idx = normalized.lastIndexOf('/');
    return idx >= 0 ? normalized.substring(idx + 1) : normalized;
  }

  // ── Server addresses ──────────────────────────────────────────────────────

  Future<List<String>> getSavedAddresses() async {
    final p = await SharedPreferences.getInstance();
    return p.getStringList(_savedAddressesKey) ?? [];
  }

  Future<void> saveAddress(String address) async {
    final p = await SharedPreferences.getInstance();
    var list = p.getStringList(_savedAddressesKey) ?? [];
    list.removeWhere((a) => a.toLowerCase() == address.toLowerCase());
    list.insert(0, address);
    if (list.length > _maxSaved) list = list.sublist(0, _maxSaved);
    await p.setStringList(_savedAddressesKey, list);
    await p.setString(_lastAddressKey, address);
  }

  Future<String?> getLastAddress() async {
    final p = await SharedPreferences.getInstance();
    return p.getString(_lastAddressKey);
  }

  // ── Nodes (servers) ───────────────────────────────────────────────────────

  /// Loads all configured nodes. If none exist yet, tries to migrate from the
  /// legacy `host:port` storage (`getLastAddress`). If no legacy value exists,
  /// returns an empty list.
  Future<List<NodeConfig>> loadNodes() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getStringList(_nodesJsonKey) ?? [];
    final parsed = <NodeConfig>[];
    for (final s in raw) {
      try {
        final m = json.decode(s) as Map<String, dynamic>;
        final node = NodeConfig.fromJson(m);
        if (node.host.isEmpty) continue;
        parsed.add(node);
      } catch (_) {}
    }

    if (parsed.isNotEmpty) return parsed;

    // Legacy migration: use lastAddress or first saved address if present.
    final legacy = (p.getString(_lastAddressKey) ??
            (p.getStringList(_savedAddressesKey)?.firstOrNull))
        ?.trim();
    if (legacy != null && legacy.isNotEmpty) {
      final migrated = _nodeFromLegacyAddress(legacy);
      final nodes = [migrated];
      await saveNodes(nodes);
      await setLastNodeId(migrated.id);
      return nodes;
    }
    return const [];
  }

  Future<void> saveNodes(List<NodeConfig> nodes) async {
    final p = await SharedPreferences.getInstance();
    final jsonList = nodes.map((n) => json.encode(n.toJson())).toList();
    await p.setStringList(_nodesJsonKey, jsonList);
  }

  Future<String?> loadLastNodeId() async {
    final p = await SharedPreferences.getInstance();
    final id = p.getString(_lastNodeIdKey);
    if (id != null && id.isNotEmpty) return id;
    final nodes = await loadNodes();
    if (nodes.isEmpty) return null;
    await setLastNodeId(nodes.first.id);
    return nodes.first.id;
  }

  Future<void> setLastNodeId(String nodeId) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_lastNodeIdKey, nodeId);
  }

  Future<void> setLastAccountId(String accountId) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_lastAccountIdKey, accountId.trim());
  }

  Future<List<String>> loadAccountIds() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getStringList(_accountIdsKey);
    final out = <String>[];

    // New schema: accounts are managed independently from servers.
    // IMPORTANT: do not early-return when this list is non-empty.
    // We merge with discoverable scoped data below so accounts can recover
    // after partial prefs corruption or stale list writes.
    if (raw != null) {
      for (final id in raw) {
        final trimmed = id.trim();
        if (trimmed.isEmpty || out.contains(trimmed)) continue;
        out.add(trimmed);
      }
    }

    // One-time legacy bootstrap.
    // New model keeps accounts independent from servers, so we only restore:
    // 1) explicit node.accountId values, or
    // 2) node.id values that already have account-scoped data saved.
    final nodes = await loadNodes();
    for (final n in nodes) {
      final explicit = n.accountId.trim();
      if (explicit.isNotEmpty) {
        if (!out.contains(explicit)) out.add(explicit);
        continue;
      }
      final legacyId = n.id.trim();
      if (legacyId.isEmpty || out.contains(legacyId)) continue;
      if (_hasAnyAccountScopedData(p, legacyId)) {
        out.add(legacyId);
      }
    }

    // Recover accounts from account-scoped keys as well (always merge).
    final prefixes = <String>[
      '${_accountMarkerKey}_',
      '${_privKeyB64Key}_',
      '${_contactEntriesJsonKey}_',
      '${_userAvatarB64Key}_',
      '${_userNicknameKey}_',
      '${_userUsernameKey}_',
    ];
    for (final key in p.getKeys()) {
      for (final prefix in prefixes) {
        if (!key.startsWith(prefix)) continue;
        final accountId = key.substring(prefix.length).trim();
        if (accountId.isEmpty || out.contains(accountId)) continue;
        out.add(accountId);
      }
    }

    // Ensure account markers exist for all recovered IDs.
    for (final id in out) {
      await p.setBool(_scopedKey(_accountMarkerKey, id), true);
    }
    await p.setStringList(_accountIdsKey, out);
    return out;
  }

  bool _hasAnyAccountScopedData(SharedPreferences p, String accountId) {
    final id = accountId.trim();
    if (id.isEmpty) return false;
    final priv = p.getString(_scopedKey(_privKeyB64Key, id));
    if (priv != null && priv.isNotEmpty) return true;
    final wl = p.getStringList(_scopedKey(_contactEntriesJsonKey, id));
    if (wl != null && wl.isNotEmpty) return true;
    final avatar = p.getString(_scopedKey(_userAvatarB64Key, id));
    if (avatar != null && avatar.isNotEmpty) return true;
    final nick = p.getString(_scopedKey(_userNicknameKey, id));
    if (nick != null && nick.trim().isNotEmpty) return true;
    final username = p.getString(_scopedKey(_userUsernameKey, id));
    if (username != null && username.trim().isNotEmpty) return true;
    return false;
  }

  Future<void> upsertAccountId(String accountId) async {
    final id = accountId.trim();
    if (id.isEmpty) return;
    final p = await SharedPreferences.getInstance();
    final list = await loadAccountIds();
    if (!list.contains(id)) {
      list.add(id);
      await p.setStringList(_accountIdsKey, list);
    }
    await p.setBool(_scopedKey(_accountMarkerKey, id), true);
    final last = await loadLastAccountId();
    if (last == null || last.isEmpty) {
      await setLastAccountId(id);
    }
  }

  Future<void> deleteAccountId(String accountId) async {
    final id = accountId.trim();
    if (id.isEmpty) return;
    final p = await SharedPreferences.getInstance();
    final list = await loadAccountIds();
    list.removeWhere((x) => x == id);
    await p.setStringList(_accountIdsKey, list);
    await p.remove(_scopedKey(_accountMarkerKey, id));
    final last = await loadLastAccountId();
    if (last == id) {
      if (list.isNotEmpty) {
        await setLastAccountId(list.first);
      } else {
        await p.remove(_lastAccountIdKey);
      }
    }
  }

  Future<String?> loadLastAccountId() async {
    final p = await SharedPreferences.getInstance();
    final id = (p.getString(_lastAccountIdKey) ?? '').trim();
    return id.isEmpty ? null : id;
  }

  Future<NodeConfig?> loadPreferredNode() async {
    final nodes = await loadNodes();
    if (nodes.isEmpty) return null;
    final id = await loadLastNodeId();
    final match = nodes.where((n) => n.id == id).firstOrNull;
    return match ?? nodes.first;
  }

  Future<NodeConfig> upsertNode(NodeConfig node) async {
    final nodes = await loadNodes();
    final idx = nodes.indexWhere((n) => n.id == node.id);
    final next = [...nodes];
    if (idx >= 0) {
      next[idx] = node;
    } else {
      next.add(node);
    }
    await saveNodes(next);
    final lastId = await loadLastNodeId();
    if (lastId == null || lastId.isEmpty) {
      await setLastNodeId(node.id);
    }
    return node;
  }

  Future<void> deleteNode(String nodeId) async {
    final nodes = await loadNodes();
    final next = nodes.where((n) => n.id != nodeId).toList();
    await saveNodes(next);
    final currentLast = await loadLastNodeId();
    if (currentLast == nodeId) {
      final p = await SharedPreferences.getInstance();
      if (next.isNotEmpty) {
        await setLastNodeId(next.first.id);
      } else {
        await p.remove(_lastNodeIdKey);
      }
    }
  }

  // ── Server options (transport discovery cache) ────────────────────────────

  Future<void> saveNodeServerOptions(
      String nodeId, SgtpServerOptions options) async {
    final id = nodeId.trim();
    if (id.isEmpty) return;
    final p = await SharedPreferences.getInstance();
    final bytesB64 = base64.encode(options.toBytes());
    await p.setString('$_nodeServerOptionsKeyPrefix$id', bytesB64);
    await p.setInt('$_nodeServerOptionsSavedAtKeyPrefix$id',
        DateTime.now().millisecondsSinceEpoch);
  }

  Future<SgtpServerOptions?> loadNodeServerOptions(String nodeId) async {
    final id = nodeId.trim();
    if (id.isEmpty) return null;
    final p = await SharedPreferences.getInstance();
    final b64 = p.getString('$_nodeServerOptionsKeyPrefix$id');
    if (b64 == null || b64.isEmpty) return null;
    try {
      final bytes = base64.decode(b64);
      return SgtpServerOptions.fromBytes(Uint8List.fromList(bytes));
    } catch (_) {
      return null;
    }
  }

  Future<DateTime?> loadNodeServerOptionsSavedAt(String nodeId) async {
    final id = nodeId.trim();
    if (id.isEmpty) return null;
    final p = await SharedPreferences.getInstance();
    final ts = p.getInt('$_nodeServerOptionsSavedAtKeyPrefix$id');
    if (ts == null || ts <= 0) return null;
    return DateTime.fromMillisecondsSinceEpoch(ts);
  }

  Future<void> saveNodeEditorAdvancedExpanded(bool expanded) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_nodeEditorAdvancedExpandedKey, expanded);
  }

  Future<bool> loadNodeEditorAdvancedExpanded() async {
    final p = await SharedPreferences.getInstance();
    return p.getBool(_nodeEditorAdvancedExpandedKey) ?? false;
  }

  NodeConfig _nodeFromLegacyAddress(String address) {
    final cleaned = address
        .trim()
        .replaceAll(RegExp(r'^https?://', caseSensitive: false), '')
        .replaceAll(RegExp(r'^wss?://', caseSensitive: false), '')
        .trim();
    var host = 'localhost';
    var port = 443;
    if (cleaned.isNotEmpty) {
      final parts = cleaned.split(':');
      if (parts.length >= 2) {
        host = parts.sublist(0, parts.length - 1).join(':').trim();
        port = int.tryParse(parts.last.trim()) ?? 443;
      } else {
        host = cleaned;
      }
    }
    final id = uuidBytesToHex(generateUUIDv7());
    return NodeConfig(
      id: id,
      name: 'Connection',
      host: host.isEmpty ? 'localhost' : host,
      chatPort: port,
      voicePort: port,
    );
  }

  // ── Private key ───────────────────────────────────────────────────────────

  Future<void> migrateLegacyAccountDataToNodeIfNeeded(String nodeId) async {
    final p = await SharedPreferences.getInstance();
    if (p.getBool(_accountsMigratedV1Key) == true) return;

    final scopedPriv = _scopedKey(_privKeyB64Key, nodeId);
    final scopedPrivName = _scopedKey(_privKeyNameKey, nodeId);
    final scopedWl = _scopedKey(_contactEntriesJsonKey, nodeId);
    final scopedAvatar = _scopedKey(_userAvatarB64Key, nodeId);
    final scopedNick = _scopedKey(_userNicknameKey, nodeId);

    // Only migrate into the preferred node if it has no scoped data yet.
    if (p.getString(scopedPriv) == null) {
      final legacy = p.getString(_privKeyB64Key);
      if (legacy != null) await p.setString(scopedPriv, legacy);
    }
    if (p.getString(scopedPrivName) == null) {
      final legacy = p.getString(_privKeyNameKey);
      if (legacy != null) await p.setString(scopedPrivName, legacy);
    }
    if (p.getStringList(scopedWl) == null) {
      final legacy = p.getStringList(_contactEntriesJsonKey);
      if (legacy != null) await p.setStringList(scopedWl, legacy);
    }
    if (p.getString(scopedAvatar) == null) {
      final legacy = p.getString(_userAvatarB64Key);
      if (legacy != null) await p.setString(scopedAvatar, legacy);
    }
    if (p.getString(scopedNick) == null) {
      final legacy = p.getString(_userNicknameKey);
      if (legacy != null) await p.setString(scopedNick, legacy);
    }
    await p.setBool(_accountsMigratedV1Key, true);
  }

  Future<void> savePrivateKey(Uint8List bytes, String name) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_privKeyB64Key, base64.encode(bytes));
    await p.setString(_privKeyNameKey, name);
    // Also write to sgtp dir
    try {
      final dir = await getSgtpDirectory();
      final file = File('${dir.path}/identity');
      await file.writeAsBytes(bytes, flush: true);
    } catch (_) {}
  }

  /// Returns null if no private key has been saved yet.
  Future<({Uint8List bytes, String name})?> loadPrivateKey() async {
    final p = await SharedPreferences.getInstance();
    final b64 = p.getString(_privKeyB64Key);
    final name = p.getString(_privKeyNameKey) ?? 'identity';
    if (b64 == null) return null;
    try {
      return (bytes: base64.decode(b64), name: name);
    } catch (_) {
      return null;
    }
  }

  Future<void> clearPrivateKey() async {
    final p = await SharedPreferences.getInstance();
    await p.remove(_privKeyB64Key);
    await p.remove(_privKeyNameKey);
  }

  Future<void> savePrivateKeyForNode(
      String nodeId, Uint8List bytes, String name) async {
    if (await _localEncryptionService.isEnabled()) {
      await _localEncryptionService.saveProtectedPrivateKey(nodeId, bytes, name);
      await _removePlainPrivateKeyForNode(nodeId);
      return;
    }
    await _savePlainPrivateKeyForNode(nodeId, bytes, name);
  }

  Future<void> _savePlainPrivateKeyForNode(
    String nodeId,
    Uint8List bytes,
    String name,
  ) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_scopedKey(_privKeyB64Key, nodeId), base64.encode(bytes));
    await p.setString(_scopedKey(_privKeyNameKey, nodeId), name);
    // Also write to the account root for easier manual inspection/recovery.
    try {
      final layout = await _accountStoragePaths.resolve(nodeId);
      final root = layout.accountRootPath;
      if (root == null) return;
      final file = File('$root/identity');
      await file.writeAsBytes(bytes, flush: true);
    } catch (_) {}
  }

  Future<({Uint8List bytes, String name})?> loadPrivateKeyForNode(
      String nodeId) async {
    if (await _localEncryptionService.isEnabled()) {
      return _localEncryptionService.loadProtectedPrivateKey(nodeId);
    }
    return _loadPlainPrivateKeyForNode(nodeId);
  }

  Future<({Uint8List bytes, String name})?> _loadPlainPrivateKeyForNode(
    String nodeId,
  ) async {
    final p = await SharedPreferences.getInstance();
    final b64 = p.getString(_scopedKey(_privKeyB64Key, nodeId));
    final name = p.getString(_scopedKey(_privKeyNameKey, nodeId)) ?? 'identity';
    if (b64 == null) return null;
    try {
      return (bytes: base64.decode(b64), name: name);
    } catch (_) {
      return null;
    }
  }

  Future<void> clearPrivateKeyForNode(String nodeId) async {
    await _removePlainPrivateKeyForNode(nodeId);
    await _localEncryptionService.deleteProtectedPrivateKey(nodeId);
  }

  Future<void> _removePlainPrivateKeyForNode(String nodeId) async {
    final p = await SharedPreferences.getInstance();
    await p.remove(_scopedKey(_privKeyB64Key, nodeId));
    await p.remove(_scopedKey(_privKeyNameKey, nodeId));
    try {
      final layout = await _accountStoragePaths.resolve(nodeId);
      final root = layout.accountRootPath;
      if (root == null) return;
      final file = File('$root/identity');
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {}
  }

  Future<LocalEncryptionState> loadLocalEncryptionState() =>
      _localEncryptionService.loadState();

  Future<void> unlockLocalEncryption(String secret) =>
      _localEncryptionService.unlock(secret);

  Future<void> lockLocalEncryption() => _localEncryptionService.lock();

  Future<void> enableLocalEncryption({
    required String? currentAccountId,
    required String secret,
    required LocalEncryptionSecretMode mode,
  }) async {
    final candidateIds = <String>{
      ...await loadAccountIds(),
      if ((currentAccountId ?? '').trim().isNotEmpty) currentAccountId!.trim(),
      ((await loadLastAccountId()) ?? '').trim(),
      'default',
    }..removeWhere((value) => value.trim().isEmpty);

    final storageKeys = <String, Uint8List>{};
    for (final accountId in candidateIds) {
      final key = await _storageKeyService.loadPlaintextAccountKey(accountId);
      if (key != null && key.length == 32) {
        storageKeys[accountId] = key;
      }
    }

    final privateKeys =
        <String, ({Uint8List bytes, String name})>{};
    for (final accountId in candidateIds) {
      final scoped = await _loadPlainPrivateKeyForNode(accountId);
      if (scoped != null) {
        privateKeys[accountId] = scoped;
      }
    }
    final normalizedCurrent = (currentAccountId ?? '').trim();
    if (normalizedCurrent.isNotEmpty && !privateKeys.containsKey(normalizedCurrent)) {
      final legacy = await loadPrivateKey();
      if (legacy != null) {
        privateKeys[normalizedCurrent] = legacy;
      }
    }

    await _localEncryptionService.enable(
      rawSecret: secret,
      mode: mode,
      storageKeys: storageKeys,
      privateKeys: privateKeys,
    );

    for (final accountId in storageKeys.keys) {
      await _storageKeyService.deleteAccountKey(accountId);
    }
    for (final accountId in privateKeys.keys) {
      await _removePlainPrivateKeyForNode(accountId);
    }
    await clearPrivateKey();
  }

  Future<void> disableLocalEncryption() async {
    final protectedAccounts = await _localEncryptionService.loadProtectedAccountIds();
    for (final accountId in protectedAccounts) {
      final storageKey =
          await _localEncryptionService.loadProtectedStorageKey(accountId);
      if (storageKey != null) {
        await _storageKeyService.savePlaintextAccountKey(accountId, storageKey);
      }
      final privateKey =
          await _localEncryptionService.loadProtectedPrivateKey(accountId);
      if (privateKey != null) {
        await _savePlainPrivateKeyForNode(
          accountId,
          privateKey.bytes,
          privateKey.name,
        );
      }
    }
    await _localEncryptionService.disable();
  }

  Future<String?> loadDeviceIdForNode(String accountId) async {
    final value = (await _loadAccountStringSetting(accountId, _deviceIdKey))
        ?.trim();
    if (value == null || value.isEmpty) return null;
    return value;
  }

  Future<void> saveDeviceIdForNode(String accountId, String deviceId) async {
    final value = deviceId.trim();
    if (value.isEmpty) {
      await _deleteAccountSetting(accountId, _deviceIdKey);
      return;
    }
    await _saveAccountStringSetting(accountId, _deviceIdKey, value);
  }

  Future<String> loadOrCreateDeviceIdForNode(String accountId) async {
    final existing = await loadDeviceIdForNode(accountId);
    if (existing != null && existing.isNotEmpty) return existing;
    final generated = uuidBytesToHex(generateUUIDv7());
    await saveDeviceIdForNode(accountId, generated);
    return generated;
  }

  Future<void> clearDeviceIdForNode(String accountId) async {
    await _deleteAccountSetting(accountId, _deviceIdKey);
  }

  // ── Contact entries ───────────────────────────────────────────────────────

  /// Contact entry: public key bytes plus editable display name.
  Future<void> saveContactEntries(List<ContactEntry> entries) async {
    final p = await SharedPreferences.getInstance();
    final jsonList = entries
        .map(
            (e) => json.encode({'b64': base64.encode(e.bytes), 'name': e.name}))
        .toList();
    await p.setStringList(_contactEntriesJsonKey, jsonList);
  }

  Future<List<ContactEntry>> loadContactEntries() async {
    final p = await SharedPreferences.getInstance();
    final jsonList = p.getStringList(_contactEntriesJsonKey);
    if (jsonList == null) return [];
    final result = <ContactEntry>[];
    for (final s in jsonList) {
      try {
        final m = json.decode(s) as Map<String, dynamic>;
        result.add(ContactEntry(
          bytes: base64.decode(m['b64'] as String),
          name: m['name'] as String? ?? 'unknown',
        ));
      } catch (_) {}
    }
    return result;
  }

  Future<void> saveContactEntriesForNode(
      String nodeId, List<ContactEntry> entries) async {
    final db = await _accountDb(nodeId);
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.replaceContactEntries(
      entries
          .map(
            (entry) => MainDatabaseContactEntryRecord(
              peerPubkeyHex: entry.hexKey,
              peerPubkeyBytes: Uint8List.fromList(entry.bytes),
              displayName: entry.name,
              updatedAtMs: now,
            ),
          )
          .toList(growable: false),
    );
  }

  Future<List<ContactEntry>> loadContactEntriesForNode(String nodeId) async {
    final db = await _accountDb(nodeId);
    final rows = await db.loadContactEntries();
    return rows
        .map(
          (row) => ContactEntry(
            bytes: Uint8List.fromList(row.peerPubkeyBytes),
            name: row.displayName,
          ),
        )
        .toList(growable: false);
  }

  /// Backwards-compat helpers using old schema
  Future<void> saveLegacyContactEntries(
      List<Uint8List> bytesList, List<String> paths) async {
    final entries = List.generate(bytesList.length,
        (i) => ContactEntry(bytes: bytesList[i], name: paths[i]));
    await saveContactEntries(entries);
  }

  Future<({List<Uint8List> bytesList, List<String> paths})?>
      loadLegacyContactEntries() async {
    final entries = await loadContactEntries();
    if (entries.isEmpty) return null;
    return (
      bytesList: entries.map((e) => e.bytes).toList(),
      paths: entries.map((e) => e.name).toList(),
    );
  }

  Future<void> clearContactEntries() async {
    final p = await SharedPreferences.getInstance();
    await p.remove(_contactEntriesJsonKey);
  }

  Future<void> clearContactEntriesForNode(String nodeId) async {
    final db = await _accountDb(nodeId);
    await db.replaceContactEntries(const []);
  }

  // ── User avatar ───────────────────────────────────────────────────────────

  Future<void> saveUserAvatar(Uint8List bytes) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_userAvatarB64Key, base64.encode(bytes));
  }

  Future<Uint8List?> loadUserAvatar() async {
    final p = await SharedPreferences.getInstance();
    final b64 = p.getString(_userAvatarB64Key);
    if (b64 == null) return null;
    try {
      return base64.decode(b64);
    } catch (_) {
      return null;
    }
  }

  Future<void> clearUserAvatar() async {
    final p = await SharedPreferences.getInstance();
    await p.remove(_userAvatarB64Key);
  }

  Future<void> saveUserAvatarForNode(String nodeId, Uint8List bytes) async {
    await _saveAccountBytesSetting(nodeId, _userAvatarB64Key, bytes);
  }

  Future<Uint8List?> loadUserAvatarForNode(String nodeId) async {
    return _loadAccountBytesSetting(nodeId, _userAvatarB64Key);
  }

  Future<void> clearUserAvatarForNode(String nodeId) async {
    await _deleteAccountSetting(nodeId, _userAvatarB64Key);
  }

  // ── User nickname ────────────────────────────────────────────────────────

  Future<String> loadUserNicknameForNode(String nodeId) async {
    return await _loadAccountStringSetting(nodeId, _userNicknameKey) ?? '';
  }

  Future<void> saveUserNicknameForNode(String nodeId, String nickname) async {
    final value = nickname.trim();
    if (value.isEmpty) {
      await _deleteAccountSetting(nodeId, _userNicknameKey);
      return;
    }
    await _saveAccountStringSetting(nodeId, _userNicknameKey, value);
  }

  // ── User username ────────────────────────────────────────────────────────

  Future<String> loadUserUsernameForNode(String nodeId) async {
    return await _loadAccountStringSetting(nodeId, _userUsernameKey) ?? '';
  }

  Future<void> saveUserUsernameForNode(String nodeId, String username) async {
    final value = username.trim();
    if (value.isEmpty) {
      await _deleteAccountSetting(nodeId, _userUsernameKey);
      return;
    }
    await _saveAccountStringSetting(nodeId, _userUsernameKey, value);
  }

  // ── Media transfer ───────────────────────────────────────────────────────

  Future<MediaTransferSettings> loadMediaTransferSettings() async {
    final p = await SharedPreferences.getInstance();
    return MediaTransferSettings(
      compressFiles: p.getBool(_compressFilesKey) ?? false,
      compressPhotos: p.getBool(_compressPhotosKey) ?? false,
      compressVideos: p.getBool(_compressVideosKey) ?? false,
      mediaChunkSizeBytes: p.getInt(_mediaChunkSizeKey) ?? (100 * 1024),
    );
  }

  Future<void> saveMediaTransferSettings(MediaTransferSettings settings) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_compressFilesKey, settings.compressFiles);
    await p.setBool(_compressPhotosKey, settings.compressPhotos);
    await p.setBool(_compressVideosKey, settings.compressVideos);
    await p.setInt(_mediaChunkSizeKey, settings.mediaChunkSizeBytes);
  }

  Future<double?> loadChatScrollPosition(String accountId, String roomUUID) async {
    final trimmed = roomUUID.trim();
    if (trimmed.isEmpty) return null;
    final db = await _accountDb(accountId);
    final state = await db.loadChatUiState(trimmed);
    return state?.scrollOffset;
  }

  Future<void> saveChatScrollPosition(
    String accountId,
    String roomUUID,
    double offset,
  ) async {
    final trimmed = roomUUID.trim();
    if (trimmed.isEmpty) return;
    final db = await _accountDb(accountId);
    await db.saveChatUiState(
      MainDatabaseChatUiStateRecord(
        roomUuid: trimmed,
        scrollOffset: offset,
        updatedAtMs: DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }

  Future<UiInteractionSettings> loadUiInteractionSettings() async {
    final p = await SharedPreferences.getInstance();
    return UiInteractionSettings(
      pingIntervalSeconds: p.getInt(_pingIntervalKey) ?? 30,
      doubleTapDesktop: p.getString(_doubleTapDesktopKey) ?? 'react',
      swipeToReply: p.getBool(_swipeToReplyKey) ?? true,
      longPressMenu: p.getBool(_longPressMenuKey) ?? true,
    );
  }

  Future<void> savePingIntervalSeconds(int seconds) async {
    final p = await SharedPreferences.getInstance();
    await p.setInt(_pingIntervalKey, seconds);
  }

  Future<void> saveUiInteractionSettings(UiInteractionSettings settings) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_doubleTapDesktopKey, settings.doubleTapDesktop);
    await p.setBool(_swipeToReplyKey, settings.swipeToReply);
    await p.setBool(_longPressMenuKey, settings.longPressMenu);
  }

  // ── Capture devices ──────────────────────────────────────────────────────

  Future<String?> loadPreferredMicrophoneForNode(String nodeId) async {
    final raw =
        (await _loadAccountStringSetting(nodeId, _preferredMicIdKey))?.trim();
    if (raw == null || raw.isEmpty) return null;
    return raw;
  }

  Future<void> savePreferredMicrophoneForNode(
      String nodeId, String? microphoneId) async {
    final value = (microphoneId ?? '').trim();
    if (value.isEmpty) {
      await _deleteAccountSetting(nodeId, _preferredMicIdKey);
      return;
    }
    await _saveAccountStringSetting(nodeId, _preferredMicIdKey, value);
  }

  Future<String?> loadPreferredCameraForNode(String nodeId) async {
    final raw = (await _loadAccountStringSetting(
      nodeId,
      _preferredCameraNameKey,
    ))
        ?.trim();
    if (raw == null || raw.isEmpty) return null;
    return raw;
  }

  Future<void> savePreferredCameraForNode(
      String nodeId, String? cameraName) async {
    final value = (cameraName ?? '').trim();
    if (value.isEmpty) {
      await _deleteAccountSetting(nodeId, _preferredCameraNameKey);
      return;
    }
    await _saveAccountStringSetting(nodeId, _preferredCameraNameKey, value);
  }

  // ── QR style ─────────────────────────────────────────────────────────────

  Future<QrStyleSettings> loadQrStyleSettings() async {
    final p = await SharedPreferences.getInstance();
    return QrStyleSettings(
      presetIndex: p.getInt(_qrPresetIndexKey) ?? 0,
      primaryColorValue: p.getInt(_qrPrimaryColorKey),
      secondaryColorValue: p.getInt(_qrSecondaryColorKey),
      shapeStyle: p.getString(_qrShapeStyleKey) ?? 'smooth',
      showLogo: p.getBool(_qrShowLogoKey) ?? true,
    );
  }

  Future<void> saveQrStyleSettings(QrStyleSettings settings) async {
    final p = await SharedPreferences.getInstance();
    await p.setInt(_qrPresetIndexKey, settings.presetIndex);
    if (settings.primaryColorValue != null) {
      await p.setInt(_qrPrimaryColorKey, settings.primaryColorValue!);
    } else {
      await p.remove(_qrPrimaryColorKey);
    }
    if (settings.secondaryColorValue != null) {
      await p.setInt(_qrSecondaryColorKey, settings.secondaryColorValue!);
    } else {
      await p.remove(_qrSecondaryColorKey);
    }
    await p.setString(_qrShapeStyleKey, settings.shapeStyle);
    await p.setBool(_qrShowLogoKey, settings.showLogo);
  }

  // ── Contact profiles ──────────────────────────────────────────────────────

  Future<void> saveContactProfile(String nodeId, ContactProfile profile) async {
    final db = await _accountDb(nodeId);
    await db.saveContactProfile(
      MainDatabaseContactProfileRecord(
        peerPubkeyHex: profile.pubkeyHex,
        username: profile.username,
        fullname: profile.fullname,
        avatarBytes: profile.avatarBytes == null
            ? null
            : Uint8List.fromList(profile.avatarBytes!),
        avatarSha256Hex: profile.avatarSha256Hex,
        updatedAtMs: profile.updatedAt,
      ),
    );
  }

  Future<ContactProfile?> loadContactProfile(
      String nodeId, String pubkeyHex) async {
    final db = await _accountDb(nodeId);
    final row = await db.loadContactProfile(pubkeyHex);
    if (row == null) return null;
    return ContactProfile(
      pubkeyHex: row.peerPubkeyHex,
      username: row.username,
      fullname: row.fullname,
      avatarBytes: row.avatarBytes == null
          ? null
          : Uint8List.fromList(row.avatarBytes!),
      avatarSha256Hex: row.avatarSha256Hex,
      updatedAt: row.updatedAtMs,
    );
  }

  Future<Map<String, ContactProfile>> loadAllContactProfiles(
      String nodeId) async {
    final db = await _accountDb(nodeId);
    final rows = await db.loadAllContactProfiles();
    final result = <String, ContactProfile>{};
    for (final row in rows) {
      result[row.peerPubkeyHex] = ContactProfile(
        pubkeyHex: row.peerPubkeyHex,
        username: row.username,
        fullname: row.fullname,
        avatarBytes: row.avatarBytes == null
            ? null
            : Uint8List.fromList(row.avatarBytes!),
        avatarSha256Hex: row.avatarSha256Hex,
        updatedAt: row.updatedAtMs,
      );
    }
    return result;
  }

  // ── Friend states ─────────────────────────────────────────────────────────

  Future<Map<String, FriendStateRecord>> loadFriendStates(String nodeId) async {
    final db = await _accountDb(nodeId);
    final rows = await db.loadFriendStates();
    final out = <String, FriendStateRecord>{};
    for (final row in rows) {
      final peer = row.peerPubkeyHex.toLowerCase();
      out[peer] = FriendStateRecord(
        peerPubkeyHex: peer,
        status: row.status.isEmpty ? FriendStatus.none.name : row.status,
        roomUUIDHex: row.roomUuidHex,
        updatedAt: row.updatedAtMs,
      );
    }
    return out;
  }

  Future<void> saveFriendStates(
      String nodeId, Map<String, FriendStateRecord> states) async {
    final db = await _accountDb(nodeId);
    await db.replaceFriendStates(
      states.entries
          .map(
            (entry) => MainDatabaseFriendStateRecord(
              peerPubkeyHex: entry.key.toLowerCase(),
              status: entry.value.status,
              roomUuidHex: entry.value.roomUUIDHex,
              updatedAtMs: entry.value.updatedAt,
            ),
          )
          .toList(growable: false),
    );
  }

  Future<Set<String>> loadSuppressedContacts(String nodeId) async {
    final db = await _accountDb(nodeId);
    return db.loadSuppressedContacts();
  }

  Future<void> saveSuppressedContacts(
      String nodeId, Set<String> pubkeysHex) async {
    final set = pubkeysHex
        .map((e) => e.trim().toLowerCase())
        .where((e) => e.length == 64)
        .toSet();
    final db = await _accountDb(nodeId);
    await db.replaceSuppressedContacts(set);
  }
}

class MediaTransferSettings {
  final bool compressFiles;
  final bool compressPhotos;
  final bool compressVideos;
  final int mediaChunkSizeBytes;

  const MediaTransferSettings({
    required this.compressFiles,
    required this.compressPhotos,
    required this.compressVideos,
    required this.mediaChunkSizeBytes,
  });

  bool get shouldCompressPhotos => compressFiles && compressPhotos;
  bool get shouldCompressVideos => compressFiles && compressVideos;

  MediaTransferSettings copyWith({
    bool? compressFiles,
    bool? compressPhotos,
    bool? compressVideos,
    int? mediaChunkSizeBytes,
  }) {
    return MediaTransferSettings(
      compressFiles: compressFiles ?? this.compressFiles,
      compressPhotos: compressPhotos ?? this.compressPhotos,
      compressVideos: compressVideos ?? this.compressVideos,
      mediaChunkSizeBytes: mediaChunkSizeBytes ?? this.mediaChunkSizeBytes,
    );
  }
}

class UiInteractionSettings {
  final int pingIntervalSeconds;
  final String doubleTapDesktop;
  final bool swipeToReply;
  final bool longPressMenu;

  const UiInteractionSettings({
    required this.pingIntervalSeconds,
    required this.doubleTapDesktop,
    required this.swipeToReply,
    required this.longPressMenu,
  });

  UiInteractionSettings copyWith({
    int? pingIntervalSeconds,
    String? doubleTapDesktop,
    bool? swipeToReply,
    bool? longPressMenu,
  }) {
    return UiInteractionSettings(
      pingIntervalSeconds: pingIntervalSeconds ?? this.pingIntervalSeconds,
      doubleTapDesktop: doubleTapDesktop ?? this.doubleTapDesktop,
      swipeToReply: swipeToReply ?? this.swipeToReply,
      longPressMenu: longPressMenu ?? this.longPressMenu,
    );
  }
}

class QrStyleSettings {
  final int presetIndex;
  final int? primaryColorValue;
  final int? secondaryColorValue;
  final String shapeStyle;
  final bool showLogo;

  const QrStyleSettings({
    required this.presetIndex,
    required this.primaryColorValue,
    required this.secondaryColorValue,
    required this.shapeStyle,
    required this.showLogo,
  });

  static const _keepInt = Object();

  QrStyleSettings copyWith({
    int? presetIndex,
    Object? primaryColorValue = _keepInt,
    Object? secondaryColorValue = _keepInt,
    String? shapeStyle,
    bool? showLogo,
  }) {
    return QrStyleSettings(
      presetIndex: presetIndex ?? this.presetIndex,
      primaryColorValue: identical(primaryColorValue, _keepInt)
          ? this.primaryColorValue
          : primaryColorValue as int?,
      secondaryColorValue: identical(secondaryColorValue, _keepInt)
          ? this.secondaryColorValue
          : secondaryColorValue as int?,
      shapeStyle: shapeStyle ?? this.shapeStyle,
      showLogo: showLogo ?? this.showLogo,
    );
  }
}
