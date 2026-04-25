import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'account_storage_layout.dart';
import 'account_storage_paths.dart';

class _IoAccountStoragePaths implements AccountStoragePaths {
  static const _accountsDirectoryName = 'sgtp_accounts';

  @override
  Future<AccountStorageLayout> resolve(String accountId) async {
    final normalized = _normalizeAccountId(accountId);
    final supportDir = await getApplicationSupportDirectory();
    final accountRoot = p.join(
      supportDir.path,
      _accountsDirectoryName,
      normalized,
    );
    final mediaDir = p.join(accountRoot, 'media');
    await Directory(accountRoot).create(recursive: true);
    await Directory(mediaDir).create(recursive: true);
    return AccountStorageLayout(
      accountId: normalized,
      accountRootPath: accountRoot,
      mainDatabasePath: p.join(accountRoot, 'main.db'),
      mainDatabaseName: 'main_$normalized',
      mlsDatabasePath: p.join(accountRoot, 'mls.db'),
      mlsDatabaseName: 'mls_$normalized',
      mediaDirectoryPath: mediaDir,
    );
  }

  @override
  Future<void> deleteAccount(String accountId) async {
    final normalized = _normalizeAccountId(accountId);
    final supportDir = await getApplicationSupportDirectory();
    final dir = Directory(
      p.join(supportDir.path, _accountsDirectoryName, normalized),
    );
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
  }

  @override
  Future<void> clearAll() async {
    final supportDir = await getApplicationSupportDirectory();
    final accountsRoot = Directory(
      p.join(supportDir.path, _accountsDirectoryName),
    );
    if (await accountsRoot.exists()) {
      await accountsRoot.delete(recursive: true);
    }
  }

  String _normalizeAccountId(String accountId) {
    final trimmed = accountId.trim();
    return trimmed.isEmpty ? 'default' : trimmed;
  }
}

AccountStoragePaths createAccountStoragePathsImpl() => _IoAccountStoragePaths();
