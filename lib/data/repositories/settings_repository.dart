import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Repository for persisting user settings between sessions.
class SettingsRepository {
  static const _savedAddressesKey = 'sgtp_saved_addresses';
  static const _lastAddressKey    = 'sgtp_last_address';
  static const _privKeyB64Key     = 'sgtp_private_key_b64';
  static const _privKeyNameKey    = 'sgtp_private_key_name';
  static const _whitelistJsonKey  = 'sgtp_whitelist_json'; // [{b64, name, nick}]
  static const _userAvatarB64Key  = 'sgtp_user_avatar_b64';
  static const int _maxSaved = 10;

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

  // ── Private key ───────────────────────────────────────────────────────────

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
    final b64  = p.getString(_privKeyB64Key);
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

  // ── Whitelist ─────────────────────────────────────────────────────────────

  /// Whitelist entry: public key bytes + display name (editable)
  /// Stored as JSON list: [{b64, name}]
  Future<void> saveWhitelistEntries(List<WhitelistEntry> entries) async {
    final p = await SharedPreferences.getInstance();
    final jsonList = entries
        .map((e) => json.encode({'b64': base64.encode(e.bytes), 'name': e.name}))
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

  /// Backwards-compat helpers using old schema
  Future<void> saveWhitelist(List<Uint8List> bytesList, List<String> paths) async {
    final entries = List.generate(bytesList.length,
        (i) => WhitelistEntry(bytes: bytesList[i], name: paths[i]));
    await saveWhitelistEntries(entries);
  }

  Future<({List<Uint8List> bytesList, List<String> paths})?> loadWhitelist() async {
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

  // ── Saved chats (UUIDs) ───────────────────────────────────────────────────

  static const _savedChatsKey = 'sgtp_saved_chat_uuids';

  Future<List<String>> loadSavedChatUUIDs() async {
    final p = await SharedPreferences.getInstance();
    return p.getStringList(_savedChatsKey) ?? [];
  }

  Future<void> addSavedChat(String uuid) async {
    final p = await SharedPreferences.getInstance();
    final list = p.getStringList(_savedChatsKey) ?? [];
    if (!list.contains(uuid)) {
      list.add(uuid);
      await p.setStringList(_savedChatsKey, list);
    }
  }

  Future<void> removeSavedChat(String uuid) async {
    final p = await SharedPreferences.getInstance();
    final list = p.getStringList(_savedChatsKey) ?? [];
    list.remove(uuid);
    await p.setStringList(_savedChatsKey, list);
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
