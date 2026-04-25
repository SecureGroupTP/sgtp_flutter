import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum LocalEncryptionSecretMode {
  password,
  passphrase,
}

class LocalEncryptionState {
  const LocalEncryptionState({
    required this.enabled,
    required this.unlocked,
    required this.migrationId,
    this.mode,
  });

  const LocalEncryptionState.disabled()
      : this(
          enabled: false,
          unlocked: false,
          migrationId: 0,
        );

  final bool enabled;
  final bool unlocked;
  final int migrationId;
  final LocalEncryptionSecretMode? mode;
}

class LocalEncryptionLockedException implements Exception {
  const LocalEncryptionLockedException([this.message = 'Local encryption is locked']);

  final String message;

  @override
  String toString() => message;
}

class LocalEncryptionAuthException implements Exception {
  const LocalEncryptionAuthException([this.message = 'Invalid password or passphrase']);

  final String message;

  @override
  String toString() => message;
}

class LocalEncryptionService {
  static const int currentMigrationId = 1;
  static const int _defaultPbkdf2Iterations = 210000;

  static const String _enabledKey = 'sgtp_local_encryption_enabled_v1';
  static const String _migrationIdKey = 'sgtp_local_encryption_migration_id_v1';
  static const String _modeKey = 'sgtp_local_encryption_mode_v1';
  static const String _saltKey = 'sgtp_local_encryption_salt_v1';
  static const String _iterationsKey = 'sgtp_local_encryption_iterations_v1';
  static const String _verifierNonceKey =
      'sgtp_local_encryption_verifier_nonce_v1';
  static const String _verifierCiphertextKey =
      'sgtp_local_encryption_verifier_ciphertext_v1';
  static const String _protectedAccountsKey =
      'sgtp_local_encryption_accounts_v1';

  static const String _storageKeyNoncePrefix =
      'sgtp_local_encryption_storage_nonce_v1_';
  static const String _storageKeyCiphertextPrefix =
      'sgtp_local_encryption_storage_ciphertext_v1_';
  static const String _privateKeyNoncePrefix =
      'sgtp_local_encryption_private_nonce_v1_';
  static const String _privateKeyCiphertextPrefix =
      'sgtp_local_encryption_private_ciphertext_v1_';
  static const String _privateKeyNamePrefix =
      'sgtp_local_encryption_private_name_v1_';

  static final Cipher _cipher = AesGcm.with256bits();
  static final Random _random = Random.secure();
  static final List<int> _verifierPlaintext =
      utf8.encode('sgtp-local-encryption-verifier-v1');

  SecretKey? _sessionKey;
  final Map<String, Uint8List> _storageKeyCache = {};
  final Map<String, ({Uint8List bytes, String name})> _privateKeyCache = {};

  Future<LocalEncryptionState> loadState() async {
    final prefs = await SharedPreferences.getInstance();
    final enabled = prefs.getBool(_enabledKey) ?? false;
    if (!enabled) {
      return const LocalEncryptionState.disabled();
    }
    final mode = _decodeMode(prefs.getString(_modeKey));
    final hasMetadata = mode != null &&
        prefs.containsKey(_saltKey) &&
        prefs.containsKey(_verifierNonceKey) &&
        prefs.containsKey(_verifierCiphertextKey);
    if (!hasMetadata) {
      return const LocalEncryptionState.disabled();
    }
    return LocalEncryptionState(
      enabled: true,
      unlocked: _sessionKey != null,
      migrationId: prefs.getInt(_migrationIdKey) ?? 0,
      mode: mode,
    );
  }

  Future<bool> isEnabled() async => (await loadState()).enabled;

  Future<void> unlock(String rawSecret) async {
    final prefs = await SharedPreferences.getInstance();
    if (!(prefs.getBool(_enabledKey) ?? false)) {
      return;
    }
    final metadata = _readMetadata(prefs);
    final normalized = normalizeSecret(rawSecret, metadata.mode);
    final keyBytes = await _deriveKeyBytes(
      normalized,
      metadata.salt,
      iterations: metadata.iterations,
    );
    final sessionKey = SecretKey(keyBytes);
    try {
      final decrypted = await _decryptBytes(
        key: sessionKey,
        nonce: metadata.verifierNonce,
        ciphertext: metadata.verifierCiphertext,
      );
      if (!_bytesEqual(decrypted, _verifierPlaintext)) {
        throw const LocalEncryptionAuthException();
      }
    } on SecretBoxAuthenticationError {
      throw const LocalEncryptionAuthException();
    }

    _sessionKey = sessionKey;
    _storageKeyCache.clear();
    _privateKeyCache.clear();
  }

  Future<void> lock() async {
    _sessionKey = null;
    _storageKeyCache.clear();
    _privateKeyCache.clear();
  }

  Future<void> enable({
    required String rawSecret,
    required LocalEncryptionSecretMode mode,
    required Map<String, Uint8List> storageKeys,
    required Map<String, ({Uint8List bytes, String name})> privateKeys,
  }) async {
    final normalized = normalizeSecret(rawSecret, mode);
    final salt = _randomBytes(16);
    final iterations = _defaultPbkdf2Iterations;
    final keyBytes = await _deriveKeyBytes(
      normalized,
      salt,
      iterations: iterations,
    );
    final sessionKey = SecretKey(keyBytes);
    final verifier = await _encryptBytes(
      key: sessionKey,
      plaintext: Uint8List.fromList(_verifierPlaintext),
    );

    final prefs = await SharedPreferences.getInstance();
    final accountIds = <String>{
      ...storageKeys.keys.map(_normalizeAccountId),
      ...privateKeys.keys.map(_normalizeAccountId),
    }.toList()
      ..sort();

    await prefs.setBool(_enabledKey, true);
    await prefs.setInt(_migrationIdKey, currentMigrationId);
    await prefs.setString(_modeKey, mode.name);
    await prefs.setString(_saltKey, base64Encode(salt));
    await prefs.setInt(_iterationsKey, iterations);
    await prefs.setString(_verifierNonceKey, base64Encode(verifier.nonce));
    await prefs.setString(
      _verifierCiphertextKey,
      base64Encode(verifier.ciphertext),
    );
    await prefs.setStringList(_protectedAccountsKey, accountIds);

    for (final entry in storageKeys.entries) {
      await saveProtectedStorageKey(entry.key, entry.value, key: sessionKey);
    }
    for (final entry in privateKeys.entries) {
      await saveProtectedPrivateKey(
        entry.key,
        entry.value.bytes,
        entry.value.name,
        key: sessionKey,
      );
    }

    _sessionKey = sessionKey;
    _storageKeyCache
      ..clear()
      ..addAll({
        for (final entry in storageKeys.entries)
          _normalizeAccountId(entry.key): Uint8List.fromList(entry.value),
      });
    _privateKeyCache
      ..clear()
      ..addAll({
        for (final entry in privateKeys.entries)
          _normalizeAccountId(entry.key): (
            bytes: Uint8List.fromList(entry.value.bytes),
            name: entry.value.name,
          ),
      });
  }

  Future<void> disable() async {
    final prefs = await SharedPreferences.getInstance();
    final accounts = await loadProtectedAccountIds();
    for (final accountId in accounts) {
      await prefs.remove('$_storageKeyNoncePrefix$accountId');
      await prefs.remove('$_storageKeyCiphertextPrefix$accountId');
      await prefs.remove('$_privateKeyNoncePrefix$accountId');
      await prefs.remove('$_privateKeyCiphertextPrefix$accountId');
      await prefs.remove('$_privateKeyNamePrefix$accountId');
    }
    await prefs.remove(_enabledKey);
    await prefs.remove(_migrationIdKey);
    await prefs.remove(_modeKey);
    await prefs.remove(_saltKey);
    await prefs.remove(_iterationsKey);
    await prefs.remove(_verifierNonceKey);
    await prefs.remove(_verifierCiphertextKey);
    await prefs.remove(_protectedAccountsKey);
    await lock();
  }

  Future<void> clearAll() => disable();

  Future<Set<String>> loadProtectedAccountIds() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_protectedAccountsKey) ?? const <String>[];
    return raw
        .map(_normalizeAccountId)
        .where((value) => value.isNotEmpty)
        .toSet();
  }

  Future<void> deleteAccount(String accountId) async {
    final normalized = _normalizeAccountId(accountId);
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('$_storageKeyNoncePrefix$normalized');
    await prefs.remove('$_storageKeyCiphertextPrefix$normalized');
    await deleteProtectedPrivateKey(normalized);
    final accounts = await loadProtectedAccountIds();
    final hasStorage = prefs.containsKey('$_storageKeyCiphertextPrefix$normalized');
    if (!hasStorage && accounts.remove(normalized)) {
      final out = accounts.toList()..sort();
      await prefs.setStringList(_protectedAccountsKey, out);
    }
    _storageKeyCache.remove(normalized);
  }

  Future<void> deleteProtectedPrivateKey(String accountId) async {
    final normalized = _normalizeAccountId(accountId);
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('$_privateKeyNoncePrefix$normalized');
    await prefs.remove('$_privateKeyCiphertextPrefix$normalized');
    await prefs.remove('$_privateKeyNamePrefix$normalized');
    final accounts = await loadProtectedAccountIds();
    final hasStorage = prefs.containsKey('$_storageKeyCiphertextPrefix$normalized');
    final hasPrivate = prefs.containsKey('$_privateKeyCiphertextPrefix$normalized');
    if (!hasStorage && !hasPrivate && accounts.remove(normalized)) {
      final out = accounts.toList()..sort();
      await prefs.setStringList(_protectedAccountsKey, out);
    }
    _privateKeyCache.remove(normalized);
  }

  Future<void> saveProtectedStorageKey(
    String accountId,
    Uint8List keyBytes, {
    SecretKey? key,
  }) async {
    final sessionKey = await _requireSessionKey(override: key);
    final normalized = _normalizeAccountId(accountId);
    final encrypted = await _encryptBytes(key: sessionKey, plaintext: keyBytes);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      '$_storageKeyNoncePrefix$normalized',
      base64Encode(encrypted.nonce),
    );
    await prefs.setString(
      '$_storageKeyCiphertextPrefix$normalized',
      base64Encode(encrypted.ciphertext),
    );
    await _mergeProtectedAccount(normalized);
    _storageKeyCache[normalized] = Uint8List.fromList(keyBytes);
  }

  Future<Uint8List?> loadProtectedStorageKey(String accountId) async {
    final normalized = _normalizeAccountId(accountId);
    final cached = _storageKeyCache[normalized];
    if (cached != null) {
      return Uint8List.fromList(cached);
    }
    final sessionKey = await _requireSessionKey();
    final prefs = await SharedPreferences.getInstance();
    final nonceB64 = prefs.getString('$_storageKeyNoncePrefix$normalized');
    final ciphertextB64 =
        prefs.getString('$_storageKeyCiphertextPrefix$normalized');
    if (nonceB64 == null || ciphertextB64 == null) {
      return null;
    }
    final decrypted = await _decryptBytes(
      key: sessionKey,
      nonce: base64Decode(nonceB64),
      ciphertext: base64Decode(ciphertextB64),
    );
    _storageKeyCache[normalized] = Uint8List.fromList(decrypted);
    return Uint8List.fromList(decrypted);
  }

  Future<void> saveProtectedPrivateKey(
    String accountId,
    Uint8List bytes,
    String name, {
    SecretKey? key,
  }) async {
    final sessionKey = await _requireSessionKey(override: key);
    final normalized = _normalizeAccountId(accountId);
    final encrypted = await _encryptBytes(key: sessionKey, plaintext: bytes);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      '$_privateKeyNoncePrefix$normalized',
      base64Encode(encrypted.nonce),
    );
    await prefs.setString(
      '$_privateKeyCiphertextPrefix$normalized',
      base64Encode(encrypted.ciphertext),
    );
    await prefs.setString('$_privateKeyNamePrefix$normalized', name);
    await _mergeProtectedAccount(normalized);
    _privateKeyCache[normalized] = (
      bytes: Uint8List.fromList(bytes),
      name: name,
    );
  }

  Future<({Uint8List bytes, String name})?> loadProtectedPrivateKey(
    String accountId,
  ) async {
    final normalized = _normalizeAccountId(accountId);
    final cached = _privateKeyCache[normalized];
    if (cached != null) {
      return (
        bytes: Uint8List.fromList(cached.bytes),
        name: cached.name,
      );
    }
    final sessionKey = await _requireSessionKey();
    final prefs = await SharedPreferences.getInstance();
    final nonceB64 = prefs.getString('$_privateKeyNoncePrefix$normalized');
    final ciphertextB64 =
        prefs.getString('$_privateKeyCiphertextPrefix$normalized');
    if (nonceB64 == null || ciphertextB64 == null) {
      return null;
    }
    final name = prefs.getString('$_privateKeyNamePrefix$normalized') ?? 'identity';
    final decrypted = await _decryptBytes(
      key: sessionKey,
      nonce: base64Decode(nonceB64),
      ciphertext: base64Decode(ciphertextB64),
    );
    final result = (
      bytes: Uint8List.fromList(decrypted),
      name: name,
    );
    _privateKeyCache[normalized] = result;
    return (
      bytes: Uint8List.fromList(result.bytes),
      name: result.name,
    );
  }

  Future<bool> hasProtectedPrivateKey(String accountId) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.containsKey('$_privateKeyCiphertextPrefix${_normalizeAccountId(accountId)}');
  }

  Future<String> normalizedSecretPreview(
    String rawSecret,
    LocalEncryptionSecretMode mode,
  ) async {
    return normalizeSecret(rawSecret, mode);
  }

  String normalizeSecret(String rawSecret, LocalEncryptionSecretMode mode) {
    return switch (mode) {
      LocalEncryptionSecretMode.password => _normalizePassword(rawSecret),
      LocalEncryptionSecretMode.passphrase => _normalizePassphrase(rawSecret),
    };
  }

  Future<SecretKey> _requireSessionKey({SecretKey? override}) async {
    if (override != null) return override;
    final state = await loadState();
    if (!state.enabled) {
      throw const LocalEncryptionLockedException('Local encryption is not enabled');
    }
    if (_sessionKey == null) {
      throw const LocalEncryptionLockedException();
    }
    return _sessionKey!;
  }

  Future<void> _mergeProtectedAccount(String accountId) async {
    final prefs = await SharedPreferences.getInstance();
    final accounts = await loadProtectedAccountIds();
    if (!accounts.add(accountId)) return;
    final out = accounts.toList()..sort();
    await prefs.setStringList(_protectedAccountsKey, out);
  }

  Future<Uint8List> _deriveKeyBytes(
    String normalizedSecret,
    Uint8List salt, {
    required int iterations,
  }) async {
    final algorithm = Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: iterations,
      bits: 256,
    );
    final secretKey = await algorithm.deriveKey(
      secretKey: SecretKey(utf8.encode(normalizedSecret)),
      nonce: salt,
    );
    return Uint8List.fromList(await secretKey.extractBytes());
  }

  Future<_EncryptedBytes> _encryptBytes({
    required SecretKey key,
    required Uint8List plaintext,
  }) async {
    final nonce = _randomBytes(12);
    final box = await _cipher.encrypt(
      plaintext,
      secretKey: key,
      nonce: nonce,
    );
    return _EncryptedBytes(
      nonce: Uint8List.fromList(box.nonce),
      ciphertext: Uint8List.fromList(<int>[
        ...box.cipherText,
        ...box.mac.bytes,
      ]),
    );
  }

  Future<Uint8List> _decryptBytes({
    required SecretKey key,
    required Uint8List nonce,
    required Uint8List ciphertext,
  }) async {
    if (ciphertext.length < 16) {
      throw const FormatException('Encrypted payload is too short');
    }
    final cipherTextBytes = ciphertext.sublist(0, ciphertext.length - 16);
    final macBytes = ciphertext.sublist(ciphertext.length - 16);
    final cleartext = await _cipher.decrypt(
      SecretBox(
        cipherTextBytes,
        nonce: nonce,
        mac: Mac(macBytes),
      ),
      secretKey: key,
    );
    return Uint8List.fromList(cleartext);
  }

  _LocalEncryptionMetadata _readMetadata(SharedPreferences prefs) {
    final mode = _decodeMode(prefs.getString(_modeKey));
    final saltB64 = prefs.getString(_saltKey);
    final verifierNonceB64 = prefs.getString(_verifierNonceKey);
    final verifierCiphertextB64 = prefs.getString(_verifierCiphertextKey);
    if (mode == null ||
        saltB64 == null ||
        verifierNonceB64 == null ||
        verifierCiphertextB64 == null) {
      throw const FormatException('Local encryption metadata is incomplete');
    }
    return _LocalEncryptionMetadata(
      mode: mode,
      salt: Uint8List.fromList(base64Decode(saltB64)),
      iterations: prefs.getInt(_iterationsKey) ?? _defaultPbkdf2Iterations,
      verifierNonce: Uint8List.fromList(base64Decode(verifierNonceB64)),
      verifierCiphertext:
          Uint8List.fromList(base64Decode(verifierCiphertextB64)),
    );
  }

  LocalEncryptionSecretMode? _decodeMode(String? raw) {
    return switch ((raw ?? '').trim()) {
      'password' => LocalEncryptionSecretMode.password,
      'passphrase' => LocalEncryptionSecretMode.passphrase,
      _ => null,
    };
  }

  String _normalizePassword(String rawSecret) {
    final value = rawSecret.trim();
    if (value.isEmpty) {
      throw const FormatException('Password cannot be empty');
    }
    if (value.contains(RegExp(r'\s'))) {
      throw const FormatException('Password cannot contain spaces');
    }
    for (final rune in value.runes) {
      if (_isLatinLetter(rune) ||
          _isCyrillicLetter(rune) ||
          _isDigit(rune) ||
          _isAllowedPasswordSymbol(rune)) {
        continue;
      }
      throw const FormatException(
        'Password contains unsupported characters',
      );
    }
    return value;
  }

  String _normalizePassphrase(String rawSecret) {
    final buffer = StringBuffer();
    for (final rune in rawSecret.runes) {
      if (_isLatinLetter(rune) || _isCyrillicLetter(rune)) {
        buffer.write(String.fromCharCode(rune).toLowerCase());
      }
    }
    final normalized = buffer.toString();
    if (normalized.isEmpty) {
      throw const FormatException(
        'Passphrase must contain at least one letter',
      );
    }
    return normalized;
  }

  bool _isAllowedPasswordSymbol(int rune) {
    const symbols = <int>{
      0x23,
      0x40,
      0x5F,
      0x2D,
      0x2F,
      0x5C,
      0x21,
      0x24,
      0x25,
      0x5E,
      0x26,
      0x2A,
      0x2B,
      0x3D,
      0x2E,
      0x3F,
      0x7E,
      0x3A,
      0x3B,
      0x2C,
      0x22,
      0x28,
      0x29,
      0x5B,
      0x5D,
      0x7B,
      0x7D,
      0x7C,
    };
    return symbols.contains(rune);
  }

  bool _isDigit(int rune) => rune >= 0x30 && rune <= 0x39;

  bool _isLatinLetter(int rune) =>
      (rune >= 0x41 && rune <= 0x5A) || (rune >= 0x61 && rune <= 0x7A);

  bool _isCyrillicLetter(int rune) =>
      rune == 0x401 ||
      rune == 0x451 ||
      (rune >= 0x410 && rune <= 0x44F);

  bool _bytesEqual(List<int> left, List<int> right) {
    if (left.length != right.length) return false;
    for (var i = 0; i < left.length; i++) {
      if (left[i] != right[i]) return false;
    }
    return true;
  }

  Uint8List _randomBytes(int length) {
    return Uint8List.fromList(
      List<int>.generate(length, (_) => _random.nextInt(256)),
    );
  }

  String _normalizeAccountId(String accountId) {
    final trimmed = accountId.trim();
    return trimmed.isEmpty ? 'default' : trimmed;
  }
}

class _LocalEncryptionMetadata {
  const _LocalEncryptionMetadata({
    required this.mode,
    required this.salt,
    required this.iterations,
    required this.verifierNonce,
    required this.verifierCiphertext,
  });

  final LocalEncryptionSecretMode mode;
  final Uint8List salt;
  final int iterations;
  final Uint8List verifierNonce;
  final Uint8List verifierCiphertext;
}

class _EncryptedBytes {
  const _EncryptedBytes({
    required this.nonce,
    required this.ciphertext,
  });

  final Uint8List nonce;
  final Uint8List ciphertext;
}
