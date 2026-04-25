import 'account_storage_paths.dart';
import 'main_database.dart';
import 'main_database_backend.dart';
import 'storage_key_service.dart';

class MainDatabaseFactory {
  MainDatabaseFactory({
    required AccountStoragePaths accountStoragePaths,
    required StorageKeyService storageKeyService,
  })  : _accountStoragePaths = accountStoragePaths,
        _storageKeyService = storageKeyService;

  final AccountStoragePaths _accountStoragePaths;
  final StorageKeyService _storageKeyService;
  final Map<String, Future<MainDatabase>> _openDatabases = {};

  Future<MainDatabase> openForAccount(String accountId) {
    final normalized = accountId.trim().isEmpty ? 'default' : accountId.trim();
    return _openDatabases.putIfAbsent(
      normalized,
      () async {
        final layout = await _accountStoragePaths.resolve(normalized);
        final key = await _storageKeyService.loadOrCreateAccountKey(normalized);
        return openMainDatabase(
          accountId: normalized,
          databaseName: layout.mainDatabaseName,
          databasePath: layout.mainDatabasePath,
          encryptionKey: key,
        );
      },
    );
  }

  Future<void> closeAccount(String accountId) async {
    final normalized = accountId.trim().isEmpty ? 'default' : accountId.trim();
    final future = _openDatabases.remove(normalized);
    if (future != null) {
      final db = await future;
      await db.close();
    }
  }

  Future<void> deleteAccount(String accountId) async {
    final normalized = accountId.trim().isEmpty ? 'default' : accountId.trim();
    await closeAccount(normalized);
    final layout = await _accountStoragePaths.resolve(normalized);
    await deleteMainDatabase(
      accountId: normalized,
      databaseName: layout.mainDatabaseName,
      databasePath: layout.mainDatabasePath,
    );
    await _accountStoragePaths.deleteAccount(normalized);
  }

  Future<void> clearAll() async {
    final accountIds = _openDatabases.keys.toList(growable: false);
    for (final accountId in accountIds) {
      await closeAccount(accountId);
    }
    await _accountStoragePaths.clearAll();
  }
}
