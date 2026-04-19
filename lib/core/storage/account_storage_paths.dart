import 'account_storage_layout.dart';
import 'account_storage_paths_impl.dart';

abstract class AccountStoragePaths {
  Future<AccountStorageLayout> resolve(String accountId);
  Future<void> deleteAccount(String accountId);
  Future<void> clearAll();
}

AccountStoragePaths createAccountStoragePaths() => createAccountStoragePathsImpl();
