import 'account_storage_layout.dart';
import 'account_storage_paths.dart';

class _WebAccountStoragePaths implements AccountStoragePaths {
  @override
  Future<AccountStorageLayout> resolve(String accountId) async {
    final normalized = _normalizeAccountId(accountId);
    return AccountStorageLayout(
      accountId: normalized,
      accountRootPath: null,
      mainDatabasePath: 'sgtp_main_$normalized',
      mainDatabaseName: 'sgtp_main_$normalized',
      mlsDatabasePath: 'sgtp_mls_$normalized',
      mlsDatabaseName: 'sgtp_mls_$normalized',
      mediaDirectoryPath: null,
    );
  }

  @override
  Future<void> deleteAccount(String accountId) async {}

  @override
  Future<void> clearAll() async {}

  String _normalizeAccountId(String accountId) {
    final trimmed = accountId.trim();
    return trimmed.isEmpty ? 'default' : trimmed;
  }
}

AccountStoragePaths createAccountStoragePathsImpl() => _WebAccountStoragePaths();
