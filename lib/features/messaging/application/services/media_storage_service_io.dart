import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:sgtp_flutter/core/storage/account_storage_paths.dart';

import 'media_storage_service.dart';

MessagingMediaStorageService createMessagingMediaStorageService({
  required AccountStoragePaths accountStoragePaths,
}) =>
    _IoMessagingMediaStorageService(
      accountStoragePaths: accountStoragePaths,
    );

class _IoMessagingMediaStorageService implements MessagingMediaStorageService {
  _IoMessagingMediaStorageService({
    required AccountStoragePaths accountStoragePaths,
  }) : _accountStoragePaths = accountStoragePaths;

  final AccountStoragePaths _accountStoragePaths;

  @override
  Future<String> createRecordingPath({
    required String accountId,
    required String prefix,
    required String extension,
  }) {
    return _createUniquePath(
      accountId: accountId,
      subdirectory: 'recordings',
      prefix: prefix,
      extension: extension,
    );
  }

  @override
  Future<String> createDerivedPath({
    required String accountId,
    required String prefix,
    required String extension,
  }) {
    return _createUniquePath(
      accountId: accountId,
      subdirectory: 'derived',
      prefix: prefix,
      extension: extension,
    );
  }

  @override
  Future<String> ensureCachedFile({
    required String accountId,
    required String namespace,
    required String cacheKey,
    required List<int> bytes,
    required String extension,
  }) async {
    final dir = await _ensureSubdirectory(accountId, p.join('cache', namespace));
    final fileName =
        '${_sanitizeSegment(cacheKey)}.${_sanitizeExtension(extension)}';
    final file = File(p.join(dir.path, fileName));
    if (!await file.exists()) {
      await file.writeAsBytes(bytes, flush: true);
    }
    return file.path;
  }

  Future<String> _createUniquePath({
    required String accountId,
    required String subdirectory,
    required String prefix,
    required String extension,
  }) async {
    final dir = await _ensureSubdirectory(accountId, subdirectory);
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final fileName =
        '${_sanitizeSegment(prefix)}_$timestamp.${_sanitizeExtension(extension)}';
    return p.join(dir.path, fileName);
  }

  Future<Directory> _ensureSubdirectory(
    String accountId,
    String relativePath,
  ) async {
    final layout = await _accountStoragePaths.resolve(accountId);
    final mediaPath = layout.mediaDirectoryPath;
    if (mediaPath == null || mediaPath.trim().isEmpty) {
      throw StateError('Media directory is unavailable for account "$accountId"');
    }
    final dir = Directory(p.join(mediaPath, relativePath));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  String _sanitizeSegment(String value) {
    final trimmed = value.trim();
    final sanitized = trimmed.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_');
    return sanitized.isEmpty ? 'media' : sanitized;
  }

  String _sanitizeExtension(String extension) {
    final trimmed = extension.trim().replaceFirst(RegExp(r'^\.+'), '');
    final sanitized = trimmed.replaceAll(RegExp(r'[^A-Za-z0-9]+'), '');
    return sanitized.isEmpty ? 'bin' : sanitized;
  }
}
