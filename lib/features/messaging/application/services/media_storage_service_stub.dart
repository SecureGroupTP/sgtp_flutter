import 'package:sgtp_flutter/core/storage/account_storage_paths.dart';

import 'media_storage_service.dart';

MessagingMediaStorageService createMessagingMediaStorageService({
  required AccountStoragePaths accountStoragePaths,
}) =>
    _UnsupportedMessagingMediaStorageService();

class _UnsupportedMessagingMediaStorageService
    implements MessagingMediaStorageService {
  UnsupportedError _error() => UnsupportedError(
        'Native media file storage is not supported on this platform.',
      );

  @override
  Future<String> createDerivedPath({
    required String accountId,
    required String prefix,
    required String extension,
  }) {
    throw _error();
  }

  @override
  Future<String> createRecordingPath({
    required String accountId,
    required String prefix,
    required String extension,
  }) {
    throw _error();
  }

  @override
  Future<String> ensureCachedFile({
    required String accountId,
    required String namespace,
    required String cacheKey,
    required List<int> bytes,
    required String extension,
  }) {
    throw _error();
  }
}
