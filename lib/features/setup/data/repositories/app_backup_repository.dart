import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class BackupExportData {
  final Uint8List bytes;
  final String suggestedFileName;

  const BackupExportData({
    required this.bytes,
    required this.suggestedFileName,
  });
}

class BackupRestoreSummary {
  final int prefsImported;
  final int prefsSkipped;
  final int filesImported;
  final int filesSkipped;

  const BackupRestoreSummary({
    required this.prefsImported,
    required this.prefsSkipped,
    required this.filesImported,
    required this.filesSkipped,
  });
}

class AppBackupRepository {
  static const int _schemaVersion = 1;
  static const String _deviceIdKeyPrefix = 'sgtp_device_id_v1';
  static const String _storageKeyPrefix = 'sgtp_storage_key_v1';
  static const List<String> _docsRoots = <String>[
    'sgtp',
    'sgtp_accounts',
    'sgtp_chats',
    'sgtp_media_cache',
  ];
  static const List<String> _supportRoots = <String>[
    'sgtp_accounts',
  ];

  Future<BackupExportData> createBackup() async {
    final prefs = await SharedPreferences.getInstance();
    final docs = await getApplicationDocumentsDirectory();
    final support = await getApplicationSupportDirectory();

    final prefEntries = <Map<String, dynamic>>[];
    for (final key in prefs.getKeys().toList()..sort()) {
      if (key.startsWith(_deviceIdKeyPrefix)) continue;
      if (key.startsWith(_storageKeyPrefix)) continue;
      final value = prefs.get(key);
      final encoded = _encodePrefEntry(key, value);
      if (encoded != null) prefEntries.add(encoded);
    }

    final files = <Map<String, dynamic>>[];
    await _collectFilesForRoot(files, docs, _docsRoots, prefix: 'docs');
    await _collectFilesForRoot(files, support, _supportRoots, prefix: 'support');

    final payload = <String, dynamic>{
      'schema': _schemaVersion,
      'createdAtUtc': DateTime.now().toUtc().toIso8601String(),
      'prefs': prefEntries,
      'files': files,
    };

    final nameStamp = DateTime.now()
        .toUtc()
        .toIso8601String()
        .replaceAll(':', '-')
        .replaceAll('.', '-');
    return BackupExportData(
      bytes: Uint8List.fromList(utf8.encode(jsonEncode(payload))),
      suggestedFileName: 'sgtp-backup-$nameStamp.sgtpbackup',
    );
  }

  Future<BackupRestoreSummary> restoreFromBytes(
    Uint8List backupBytes, {
    required bool merge,
  }) async {
    final decoded = jsonDecode(utf8.decode(backupBytes));
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Backup payload is not a JSON object');
    }
    final schema = decoded['schema'];
    if (schema is! num || schema.toInt() != _schemaVersion) {
      throw FormatException('Unsupported backup schema: $schema');
    }

    final prefsRaw = decoded['prefs'];
    final filesRaw = decoded['files'];
    if (prefsRaw is! List || filesRaw is! List) {
      throw const FormatException('Backup payload is missing prefs/files');
    }

    final prefs = await SharedPreferences.getInstance();
    if (!merge) {
      await prefs.clear();
      final docs = await getApplicationDocumentsDirectory();
      final support = await getApplicationSupportDirectory();
      for (final root in _docsRoots) {
        final dir = Directory('${docs.path}/$root');
        if (await dir.exists()) {
          await dir.delete(recursive: true);
        }
      }
      for (final root in _supportRoots) {
        final dir = Directory('${support.path}/$root');
        if (await dir.exists()) {
          await dir.delete(recursive: true);
        }
      }
    }

    var prefsImported = 0;
    var prefsSkipped = 0;
    for (final raw in prefsRaw) {
      if (raw is! Map<String, dynamic>) {
        prefsSkipped++;
        continue;
      }
      final applied = await _restorePrefEntry(prefs, raw, merge: merge);
      if (applied) {
        prefsImported++;
      } else {
        prefsSkipped++;
      }
    }

    final docs = await getApplicationDocumentsDirectory();
    final support = await getApplicationSupportDirectory();
    var filesImported = 0;
    var filesSkipped = 0;
    final touchedOrderFiles = <String>{};

    for (final raw in filesRaw) {
      if (raw is! Map<String, dynamic>) {
        filesSkipped++;
        continue;
      }
      final path = (raw['path'] as String?)?.trim() ?? '';
      final b64 = raw['bytesB64'] as String?;
      if ((!path.startsWith('docs/') && !path.startsWith('support/')) ||
          b64 == null ||
          b64.isEmpty) {
        filesSkipped++;
        continue;
      }

      final isSupportPath = path.startsWith('support/');
      final relative = path.substring(isSupportPath ? 'support/'.length : 'docs/'.length);
      if (relative.isEmpty) {
        filesSkipped++;
        continue;
      }

      final baseDir = isSupportPath ? support : docs;
      final file = File('${baseDir.path}/$relative');
      final bytes = Uint8List.fromList(base64Decode(b64));
      await file.parent.create(recursive: true);

      final isOrderFile = relative.endsWith('/order.ndjson');
      if (isOrderFile) touchedOrderFiles.add(file.path);

      if (!merge) {
        await file.writeAsBytes(bytes, flush: true);
        filesImported++;
        continue;
      }

      if (!await file.exists()) {
        await file.writeAsBytes(bytes, flush: true);
        filesImported++;
        continue;
      }

      if (isOrderFile) {
        final merged = await _mergeOrderFiles(file, utf8.decode(bytes));
        if (merged) {
          filesImported++;
        } else {
          filesSkipped++;
        }
        continue;
      }

      // In merge mode we never overwrite existing file bytes.
      filesSkipped++;
    }

    await _rebuildHistoryCounts(touchedOrderFiles);

    return BackupRestoreSummary(
      prefsImported: prefsImported,
      prefsSkipped: prefsSkipped,
      filesImported: filesImported,
      filesSkipped: filesSkipped,
    );
  }

  Map<String, dynamic>? _encodePrefEntry(String key, Object? value) {
    if (value is String) {
      return <String, dynamic>{'key': key, 'type': 'string', 'value': value};
    }
    if (value is int) {
      return <String, dynamic>{'key': key, 'type': 'int', 'value': value};
    }
    if (value is double) {
      return <String, dynamic>{'key': key, 'type': 'double', 'value': value};
    }
    if (value is bool) {
      return <String, dynamic>{'key': key, 'type': 'bool', 'value': value};
    }
    if (value is List) {
      final asStrings = value.map((e) => e.toString()).toList();
      return <String, dynamic>{
        'key': key,
        'type': 'stringList',
        'value': asStrings,
      };
    }
    return null;
  }

  Future<bool> _restorePrefEntry(
    SharedPreferences prefs,
    Map<String, dynamic> entry, {
    required bool merge,
  }) async {
    final key = (entry['key'] as String?)?.trim() ?? '';
    final type = (entry['type'] as String?)?.trim() ?? '';
    final value = entry['value'];

    if (key.isEmpty || type.isEmpty) return false;
    if (key.startsWith(_deviceIdKeyPrefix)) return false;
    if (key.startsWith(_storageKeyPrefix)) return false;

    if (!merge || !prefs.containsKey(key)) {
      return _setPrefByType(prefs, key, type, value);
    }

    if (type == 'stringList') {
      final current = prefs.getStringList(key) ?? const <String>[];
      final incoming = (value as List?)?.map((e) => e.toString()).toList() ??
          const <String>[];
      final merged = <String>[...current];
      for (final item in incoming) {
        if (!merged.contains(item)) merged.add(item);
      }
      await prefs.setStringList(key, merged);
      return true;
    }

    // Scalar key already exists: keep current value in merge mode.
    return false;
  }

  Future<bool> _setPrefByType(
    SharedPreferences prefs,
    String key,
    String type,
    Object? value,
  ) async {
    switch (type) {
      case 'string':
        if (value is String) {
          await prefs.setString(key, value);
          return true;
        }
        return false;
      case 'int':
        if (value is num) {
          await prefs.setInt(key, value.toInt());
          return true;
        }
        return false;
      case 'double':
        if (value is num) {
          await prefs.setDouble(key, value.toDouble());
          return true;
        }
        return false;
      case 'bool':
        if (value is bool) {
          await prefs.setBool(key, value);
          return true;
        }
        return false;
      case 'stringList':
        final list = (value as List?)?.map((e) => e.toString()).toList();
        if (list == null) return false;
        await prefs.setStringList(key, list);
        return true;
      default:
        return false;
    }
  }

  Future<void> _collectFilesForRoot(
    List<Map<String, dynamic>> files,
    Directory baseDir,
    List<String> roots, {
    required String prefix,
  }) async {
    for (final root in roots) {
      final dir = Directory('${baseDir.path}/$root');
      if (!await dir.exists()) continue;
      await for (final entity in dir.list(recursive: true, followLinks: false)) {
        if (entity is! File) continue;
        final rel = _relativeToBase(entity.path, baseDir.path);
        if (rel == null) continue;
        final bytes = await entity.readAsBytes();
        files.add(<String, dynamic>{
          'path': '$prefix/$rel',
          'bytesB64': base64Encode(bytes),
        });
      }
    }
  }

  String? _relativeToBase(String filePath, String basePath) {
    var full = filePath.replaceAll('\\', '/');
    var base = basePath.replaceAll('\\', '/');
    if (!base.endsWith('/')) base = '$base/';
    if (!full.startsWith(base)) return null;
    return full.substring(base.length);
  }

  Future<bool> _mergeOrderFiles(File existing, String incomingContent) async {
    final currentContent = await existing.readAsString();
    final current = _splitOrderLines(currentContent);
    final incoming = _splitOrderLines(incomingContent);

    if (incoming.isEmpty) return false;

    final merged = <String>[...current];
    final seen = current.toSet();
    var changed = false;
    for (final id in incoming) {
      if (seen.add(id)) {
        merged.add(id);
        changed = true;
      }
    }

    if (!changed) return false;

    final text = merged.isEmpty ? '' : '${merged.join('\n')}\n';
    await existing.writeAsString(text, flush: true);
    return true;
  }

  List<String> _splitOrderLines(String content) {
    return content
        .split('\n')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
  }

  Future<void> _rebuildHistoryCounts(Set<String> orderFilePaths) async {
    for (final orderPath in orderFilePaths) {
      final orderFile = File(orderPath);
      if (!await orderFile.exists()) continue;
      final lines = _splitOrderLines(await orderFile.readAsString());
      final countFile = File('${orderFile.parent.path}/count.txt');
      await countFile.writeAsString('${lines.length}', flush: true);
    }
  }
}
