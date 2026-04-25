import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:shared_preferences/shared_preferences.dart';

import 'local_encryption_service.dart';

class StorageKeyService {
  StorageKeyService({
    LocalEncryptionService? localEncryptionService,
  }) : _localEncryptionService =
            localEncryptionService ?? LocalEncryptionService();

  static const _storageKeyPrefix = 'sgtp_storage_key_v1';
  final LocalEncryptionService _localEncryptionService;

  Future<Uint8List> loadOrCreateAccountKey(String accountId) async {
    final normalized = _scopedAccountId(accountId);
    if (await _localEncryptionService.isEnabled()) {
      final existing = await _localEncryptionService.loadProtectedStorageKey(
        normalized,
      );
      if (existing != null && existing.length == 32) {
        return existing;
      }
      final generated = _randomBytes(32);
      await _localEncryptionService.saveProtectedStorageKey(normalized, generated);
      return generated;
    }
    return loadOrCreatePlaintextAccountKey(normalized);
  }

  Future<Uint8List> loadOrCreatePlaintextAccountKey(String accountId) async {
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

  Future<Uint8List?> loadPlaintextAccountKey(String accountId) async {
    final prefs = await SharedPreferences.getInstance();
    final existing = prefs.getString(_scopedKey(accountId));
    if (existing == null || existing.isEmpty) return null;
    try {
      final decoded = base64Decode(existing);
      if (decoded.length == 32) {
        return Uint8List.fromList(decoded);
      }
    } catch (_) {}
    return null;
  }

  Future<void> savePlaintextAccountKey(String accountId, Uint8List keyBytes) async {
    if (keyBytes.length != 32) {
      throw const FormatException('Storage key must be 32 bytes');
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_scopedKey(accountId), base64Encode(keyBytes));
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
    final normalized = _scopedAccountId(accountId);
    return '${_storageKeyPrefix}_$normalized';
  }

  String _scopedAccountId(String accountId) {
    final normalized = accountId.trim();
    return normalized.isEmpty ? 'default' : normalized;
  }

  Uint8List _randomBytes(int length) {
    final random = Random.secure();
    return Uint8List.fromList(
      List<int>.generate(length, (_) => random.nextInt(256)),
    );
  }
}
