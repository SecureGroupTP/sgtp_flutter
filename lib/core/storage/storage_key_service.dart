import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:shared_preferences/shared_preferences.dart';

class StorageKeyService {
  static const _storageKeyPrefix = 'sgtp_storage_key_v1';

  Future<Uint8List> loadOrCreateAccountKey(String accountId) async {
    final prefs = await SharedPreferences.getInstance();
    final key = _scopedKey(accountId);
    final existing = prefs.getString(key);
    if (existing != null && existing.isNotEmpty) {
      try {
        final decoded = base64Decode(existing);
        if (decoded.length == 32) {
          return Uint8List.fromList(decoded);
        }
      } catch (_) {}
    }

    final generated = _randomBytes(32);
    await prefs.setString(key, base64Encode(generated));
    return generated;
  }

  Future<void> deleteAccountKey(String accountId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_scopedKey(accountId));
  }

  Future<void> clearAll() async {
    final prefs = await SharedPreferences.getInstance();
    final keys = prefs
        .getKeys()
        .where((key) => key.startsWith(_storageKeyPrefix))
        .toList();
    for (final key in keys) {
      await prefs.remove(key);
    }
  }

  String _scopedKey(String accountId) {
    final normalized = accountId.trim().isEmpty ? 'default' : accountId.trim();
    return '${_storageKeyPrefix}_$normalized';
  }

  Uint8List _randomBytes(int length) {
    final random = Random.secure();
    return Uint8List.fromList(
      List<int>.generate(length, (_) => random.nextInt(256)),
    );
  }
}
