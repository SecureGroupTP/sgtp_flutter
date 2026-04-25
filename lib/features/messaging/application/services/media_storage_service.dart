import 'package:sgtp_flutter/core/storage/account_storage_paths.dart';

import 'media_storage_service_stub.dart'
    if (dart.library.io) 'media_storage_service_io.dart' as impl;

abstract class MessagingMediaStorageService {
  Future<String> createRecordingPath({
    required String accountId,
    required String prefix,
    required String extension,
  });

  Future<String> createDerivedPath({
    required String accountId,
    required String prefix,
    required String extension,
  });

  Future<String> ensureCachedFile({
    required String accountId,
    required String namespace,
    required String cacheKey,
    required List<int> bytes,
    required String extension,
  });
}

MessagingMediaStorageService createMessagingMediaStorageService({
  required AccountStoragePaths accountStoragePaths,
}) =>
    impl.createMessagingMediaStorageService(
      accountStoragePaths: accountStoragePaths,
    );
