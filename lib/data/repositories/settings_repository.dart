import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/sgtp_server_options.dart';
import '../../core/uuid_v7.dart';
import '../../domain/entities/node.dart';

/// Repository for persisting user settings between sessions.
class SettingsRepository {
  static const _savedAddressesKey = 'sgtp_saved_addresses';
  static const _lastAddressKey = 'sgtp_last_address';
  static const _nodesJsonKey =
      'sgtp_nodes_json_v1'; // [{id,name,host,chatPort,voicePort}]
  static const _lastNodeIdKey = 'sgtp_last_node_id';
  static const _lastAccountIdKey = 'sgtp_last_account_id';
  static const _accountIdsKey = 'sgtp_account_ids_v1';
  // Legacy (global) identity + profile keys. New code should prefer per-account scoped variants.
  static const _privKeyB64Key = 'sgtp_private_key_b64';
  static const _privKeyNameKey = 'sgtp_private_key_name';
  static const _whitelistJsonKey = 'sgtp_whitelist_json'; // [{b64, name}]
  static const _userAvatarB64Key = 'sgtp_user_avatar_b64';
  static const _userNicknameKey = 'sgtp_user_nickname';
  static const _userUsernameKey = 'sgtp_user_username';

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
  static const _contactProfilesKey = 'sgtp_contact_profiles';
  static const _nodeServerOptionsKeyPrefix = 'sgtp_node_server_options_v1_';
  static const _nodeServerOptionsSavedAtKeyPrefix =
      'sgtp_node_server_options_saved_at_v1_';
  static const int _maxSaved = 10;

  String _scopedKey(String base, String? nodeId) {
    final id = (nodeId ?? '').trim();
    if (id.isEmpty) return base;
    return '${base}_$id';
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
    await p.clear();

    final docsDir = await getApplicationDocumentsDirectory();
    final folders = <Directory>[
      Directory('${docsDir.path}/sgtp'),
      Directory('${docsDir.path}/sgtp_accounts'),
      Directory('${docsDir.path}/sgtp_chats'),
    ];
    for (final dir in folders) {
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    }
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
    if (raw != null) {
      for (final id in raw) {
        final trimmed = id.trim();
        if (trimmed.isEmpty || out.contains(trimmed)) continue;
        out.add(trimmed);
      }
      return out;
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
    await p.setStringList(_accountIdsKey, out);
    return out;
  }

  bool _hasAnyAccountScopedData(SharedPreferences p, String accountId) {
    final id = accountId.trim();
    if (id.isEmpty) return false;
    final priv = p.getString(_scopedKey(_privKeyB64Key, id));
    if (priv != null && priv.isNotEmpty) return true;
    final wl = p.getStringList(_scopedKey(_whitelistJsonKey, id));
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
    final scopedWl = _scopedKey(_whitelistJsonKey, nodeId);
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
      final legacy = p.getStringList(_whitelistJsonKey);
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
    final p = await SharedPreferences.getInstance();
    await p.setString(_scopedKey(_privKeyB64Key, nodeId), base64.encode(bytes));
    await p.setString(_scopedKey(_privKeyNameKey, nodeId), name);
    // Also write to sgtp dir (account-scoped filename).
    try {
      final dir = await getSgtpDirectory();
      final safe = nodeId.replaceAll(RegExp(r'[^a-zA-Z0-9_-]+'), '');
      final fileName = safe.isEmpty ? 'identity' : 'identity_$safe';
      final file = File('${dir.path}/$fileName');
      await file.writeAsBytes(bytes, flush: true);
    } catch (_) {}
  }

  Future<({Uint8List bytes, String name})?> loadPrivateKeyForNode(
      String nodeId) async {
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
    final p = await SharedPreferences.getInstance();
    await p.remove(_scopedKey(_privKeyB64Key, nodeId));
    await p.remove(_scopedKey(_privKeyNameKey, nodeId));
  }

  // ── Whitelist ─────────────────────────────────────────────────────────────

  /// Whitelist entry: public key bytes + display name (editable)
  /// Stored as JSON list: [{b64, name}]
  Future<void> saveWhitelistEntries(List<WhitelistEntry> entries) async {
    final p = await SharedPreferences.getInstance();
    final jsonList = entries
        .map(
            (e) => json.encode({'b64': base64.encode(e.bytes), 'name': e.name}))
        .toList();
    await p.setStringList(_whitelistJsonKey, jsonList);
  }

  Future<List<WhitelistEntry>> loadWhitelistEntries() async {
    final p = await SharedPreferences.getInstance();
    final jsonList = p.getStringList(_whitelistJsonKey);
    if (jsonList == null) return [];
    final result = <WhitelistEntry>[];
    for (final s in jsonList) {
      try {
        final m = json.decode(s) as Map<String, dynamic>;
        result.add(WhitelistEntry(
          bytes: base64.decode(m['b64'] as String),
          name: m['name'] as String? ?? 'unknown',
        ));
      } catch (_) {}
    }
    return result;
  }

  Future<void> saveWhitelistEntriesForNode(
      String nodeId, List<WhitelistEntry> entries) async {
    final p = await SharedPreferences.getInstance();
    final jsonList = entries
        .map(
            (e) => json.encode({'b64': base64.encode(e.bytes), 'name': e.name}))
        .toList();
    await p.setStringList(_scopedKey(_whitelistJsonKey, nodeId), jsonList);
  }

  Future<List<WhitelistEntry>> loadWhitelistEntriesForNode(
      String nodeId) async {
    final p = await SharedPreferences.getInstance();
    final jsonList = p.getStringList(_scopedKey(_whitelistJsonKey, nodeId));
    if (jsonList == null) return [];
    final result = <WhitelistEntry>[];
    for (final s in jsonList) {
      try {
        final m = json.decode(s) as Map<String, dynamic>;
        result.add(WhitelistEntry(
          bytes: base64.decode(m['b64'] as String),
          name: m['name'] as String? ?? 'unknown',
        ));
      } catch (_) {}
    }
    return result;
  }

  /// Backwards-compat helpers using old schema
  Future<void> saveWhitelist(
      List<Uint8List> bytesList, List<String> paths) async {
    final entries = List.generate(bytesList.length,
        (i) => WhitelistEntry(bytes: bytesList[i], name: paths[i]));
    await saveWhitelistEntries(entries);
  }

  Future<({List<Uint8List> bytesList, List<String> paths})?>
      loadWhitelist() async {
    final entries = await loadWhitelistEntries();
    if (entries.isEmpty) return null;
    return (
      bytesList: entries.map((e) => e.bytes).toList(),
      paths: entries.map((e) => e.name).toList(),
    );
  }

  Future<void> clearWhitelist() async {
    final p = await SharedPreferences.getInstance();
    await p.remove(_whitelistJsonKey);
  }

  Future<void> clearWhitelistForNode(String nodeId) async {
    final p = await SharedPreferences.getInstance();
    await p.remove(_scopedKey(_whitelistJsonKey, nodeId));
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
    final p = await SharedPreferences.getInstance();
    await p.setString(
        _scopedKey(_userAvatarB64Key, nodeId), base64.encode(bytes));
  }

  Future<Uint8List?> loadUserAvatarForNode(String nodeId) async {
    final p = await SharedPreferences.getInstance();
    final b64 = p.getString(_scopedKey(_userAvatarB64Key, nodeId));
    if (b64 == null) return null;
    try {
      return base64.decode(b64);
    } catch (_) {
      return null;
    }
  }

  Future<void> clearUserAvatarForNode(String nodeId) async {
    final p = await SharedPreferences.getInstance();
    await p.remove(_scopedKey(_userAvatarB64Key, nodeId));
  }

  // ── User nickname ────────────────────────────────────────────────────────

  Future<String> loadUserNicknameForNode(String nodeId) async {
    final p = await SharedPreferences.getInstance();
    return p.getString(_scopedKey(_userNicknameKey, nodeId)) ?? '';
  }

  Future<void> saveUserNicknameForNode(String nodeId, String nickname) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_scopedKey(_userNicknameKey, nodeId), nickname.trim());
  }

  // ── User username ────────────────────────────────────────────────────────

  Future<String> loadUserUsernameForNode(String nodeId) async {
    final p = await SharedPreferences.getInstance();
    return p.getString(_scopedKey(_userUsernameKey, nodeId)) ?? '';
  }

  Future<void> saveUserUsernameForNode(String nodeId, String username) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_scopedKey(_userUsernameKey, nodeId), username.trim());
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

  // ── Capture devices ──────────────────────────────────────────────────────

  Future<String?> loadPreferredMicrophoneForNode(String nodeId) async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_scopedKey(_preferredMicIdKey, nodeId))?.trim();
    if (raw == null || raw.isEmpty) return null;
    return raw;
  }

  Future<void> savePreferredMicrophoneForNode(
      String nodeId, String? microphoneId) async {
    final p = await SharedPreferences.getInstance();
    final key = _scopedKey(_preferredMicIdKey, nodeId);
    final value = (microphoneId ?? '').trim();
    if (value.isEmpty) {
      await p.remove(key);
      return;
    }
    await p.setString(key, value);
  }

  Future<String?> loadPreferredCameraForNode(String nodeId) async {
    final p = await SharedPreferences.getInstance();
    final raw =
        p.getString(_scopedKey(_preferredCameraNameKey, nodeId))?.trim();
    if (raw == null || raw.isEmpty) return null;
    return raw;
  }

  Future<void> savePreferredCameraForNode(
      String nodeId, String? cameraName) async {
    final p = await SharedPreferences.getInstance();
    final key = _scopedKey(_preferredCameraNameKey, nodeId);
    final value = (cameraName ?? '').trim();
    if (value.isEmpty) {
      await p.remove(key);
      return;
    }
    await p.setString(key, value);
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

  Future<Directory> _contactAvatarDir(String nodeId) async {
    final base = await getSgtpDirectory();
    final dir = Directory('${base.path}/contact_avatars/$nodeId');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<void> saveContactProfile(String nodeId, ContactProfile profile) async {
    final p = await SharedPreferences.getInstance();
    final key = _scopedKey(_contactProfilesKey, nodeId);
    final raw = p.getString(key);
    final map = raw != null
        ? (json.decode(raw) as Map<String, dynamic>)
        : <String, dynamic>{};
    map[profile.pubkeyHex] = {
      'username': profile.username,
      'fullname': profile.fullname,
      'sha256': profile.avatarSha256Hex,
      'updatedAt': profile.updatedAt,
    };
    await p.setString(key, json.encode(map));
    if (profile.avatarBytes != null && profile.avatarBytes!.isNotEmpty) {
      final dir = await _contactAvatarDir(nodeId);
      final file = File('${dir.path}/${profile.pubkeyHex}.bin');
      await file.writeAsBytes(profile.avatarBytes!);
    }
  }

  Future<ContactProfile?> loadContactProfile(
      String nodeId, String pubkeyHex) async {
    final p = await SharedPreferences.getInstance();
    final key = _scopedKey(_contactProfilesKey, nodeId);
    final raw = p.getString(key);
    if (raw == null) return null;
    final map = json.decode(raw) as Map<String, dynamic>;
    final entry = map[pubkeyHex] as Map<String, dynamic>?;
    if (entry == null) return null;

    Uint8List? avatar;
    final dir = await _contactAvatarDir(nodeId);
    final file = File('${dir.path}/$pubkeyHex.bin');
    if (await file.exists()) avatar = await file.readAsBytes();

    return ContactProfile(
      pubkeyHex: pubkeyHex,
      username: entry['username'] as String?,
      fullname: entry['fullname'] as String?,
      avatarBytes: avatar,
      avatarSha256Hex: entry['sha256'] as String? ?? '',
      updatedAt: entry['updatedAt'] as int? ?? 0,
    );
  }

  Future<Map<String, ContactProfile>> loadAllContactProfiles(
      String nodeId) async {
    final p = await SharedPreferences.getInstance();
    final key = _scopedKey(_contactProfilesKey, nodeId);
    final raw = p.getString(key);
    if (raw == null) return {};
    final map = json.decode(raw) as Map<String, dynamic>;
    final result = <String, ContactProfile>{};
    final dir = await _contactAvatarDir(nodeId);
    for (final kv in map.entries) {
      final pubkeyHex = kv.key;
      final data = kv.value as Map<String, dynamic>;
      Uint8List? avatar;
      final file = File('${dir.path}/$pubkeyHex.bin');
      if (await file.exists()) avatar = await file.readAsBytes();
      result[pubkeyHex] = ContactProfile(
        pubkeyHex: pubkeyHex,
        username: data['username'] as String?,
        fullname: data['fullname'] as String?,
        avatarBytes: avatar,
        avatarSha256Hex: data['sha256'] as String? ?? '',
        updatedAt: data['updatedAt'] as int? ?? 0,
      );
    }
    return result;
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

/// A whitelist entry: a trusted peer's public key + editable display name.
class WhitelistEntry {
  final Uint8List bytes;
  final String name;

  WhitelistEntry({required this.bytes, required this.name});

  String get hexKey =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  WhitelistEntry copyWithName(String newName) =>
      WhitelistEntry(bytes: bytes, name: newName);
}

/// Cached profile data fetched from the userdir service.
class ContactProfile {
  final String pubkeyHex;
  final String? username;
  final String? fullname;
  final Uint8List? avatarBytes;
  final String avatarSha256Hex; // 64-char hex; empty string if not set
  final int updatedAt; // unix seconds

  const ContactProfile({
    required this.pubkeyHex,
    this.username,
    this.fullname,
    this.avatarBytes,
    required this.avatarSha256Hex,
    required this.updatedAt,
  });
}
