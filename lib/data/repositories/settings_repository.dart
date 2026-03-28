import 'dart:convert';
import 'dart:typed_data';

import 'package:shared_preferences/shared_preferences.dart';

/// Repository for persisting user settings between sessions.
class SettingsRepository {
  static const _savedAddressesKey = 'sgtp_saved_addresses';
  static const _lastAddressKey    = 'sgtp_last_address';
  static const _privKeyB64Key     = 'sgtp_private_key_b64';
  static const _privKeyPathKey    = 'sgtp_private_key_path';
  static const _whitelistB64Key   = 'sgtp_whitelist_b64_list';
  static const _whitelistPathsKey = 'sgtp_whitelist_paths';
  static const int _maxSaved = 10;

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

  Future<void> savePrivateKey(Uint8List bytes, String path) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_privKeyB64Key, base64.encode(bytes));
    await p.setString(_privKeyPathKey, path);
  }

  /// Returns null if no private key has been saved yet.
  Future<({Uint8List bytes, String path})?> loadPrivateKey() async {
    final p = await SharedPreferences.getInstance();
    final b64  = p.getString(_privKeyB64Key);
    final path = p.getString(_privKeyPathKey);
    if (b64 == null || path == null) return null;
    try {
      return (bytes: base64.decode(b64), path: path);
    } catch (_) {
      return null;
    }
  }

  Future<void> clearPrivateKey() async {
    final p = await SharedPreferences.getInstance();
    await p.remove(_privKeyB64Key);
    await p.remove(_privKeyPathKey);
  }

  // ── Whitelist ─────────────────────────────────────────────────────────────

  /// Saves whitelist public key bytes and corresponding file names.
  Future<void> saveWhitelist(List<Uint8List> bytesList, List<String> paths) async {
    final p = await SharedPreferences.getInstance();
    final b64List = bytesList.map((b) => base64.encode(b)).toList();
    await p.setStringList(_whitelistB64Key, b64List);
    await p.setStringList(_whitelistPathsKey, paths);
  }

  /// Returns null if no whitelist has been saved yet.
  Future<({List<Uint8List> bytesList, List<String> paths})?> loadWhitelist() async {
    final p = await SharedPreferences.getInstance();
    final b64List = p.getStringList(_whitelistB64Key);
    final paths   = p.getStringList(_whitelistPathsKey);
    if (b64List == null || paths == null || b64List.length != paths.length) return null;
    try {
      final bytesList = b64List.map((s) => base64.decode(s)).toList();
      return (bytesList: bytesList, paths: paths);
    } catch (_) {
      return null;
    }
  }

  Future<void> clearWhitelist() async {
    final p = await SharedPreferences.getInstance();
    await p.remove(_whitelistB64Key);
    await p.remove(_whitelistPathsKey);
  }
}
