class AccountStorageLayout {
  const AccountStorageLayout({
    required this.accountId,
    required this.accountRootPath,
    required this.mainDatabasePath,
    required this.mainDatabaseName,
    required this.mlsDatabasePath,
    required this.mlsDatabaseName,
    required this.mediaDirectoryPath,
  });

  final String accountId;
  final String? accountRootPath;
  final String mainDatabasePath;
  final String mainDatabaseName;
  final String mlsDatabasePath;
  final String mlsDatabaseName;
  final String? mediaDirectoryPath;
}
