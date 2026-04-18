import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:path_provider/path_provider.dart';
import 'package:sgtp_chat_core/sgtp_chat_core.dart';

import 'package:sgtp_flutter/core/app_log.dart';
import 'package:sgtp_flutter/core/network/rpc_models/mls_rpc_models.dart';
import 'package:sgtp_flutter/core/network/sgtp_connection_service.dart';
import 'package:sgtp_flutter/features/messaging/data/services/server_v2_mls_client.dart';
import 'package:sgtp_flutter/features/messaging/domain/entities/sgtp_config.dart';
import 'package:sgtp_flutter/features/messaging/domain/repositories/key_package_publisher.dart';

class SharedKeyPackagePublisher implements KeyPackagePublisher {
  SharedKeyPackagePublisher({
    required SgtpConnectionService connectionService,
  }) : _connectionService = connectionService;

  final SgtpConnectionService _connectionService;
  final _log = AppLog('SharedKeyPackagePublisher');
  final Map<String, Future<void>> _inFlightByKey = {};
  final Set<String> _uploadedKeys = <String>{};

  @override
  Future<void> ensureUploaded(SgtpConfig config) async {
    final key = _cacheKey(config);
    if (_uploadedKeys.contains(key)) {
      return;
    }
    final inFlight = _inFlightByKey[key];
    if (inFlight != null) {
      return inFlight;
    }
    final future = _ensureUploadedInternal(config, key);
    _inFlightByKey[key] = future;
    try {
      await future;
    } finally {
      if (identical(_inFlightByKey[key], future)) {
        _inFlightByKey.remove(key);
      }
    }
  }

  @override
  void invalidateForConfig(SgtpConfig config) {
    _uploadedKeys.remove(_cacheKey(config));
    _inFlightByKey.remove(_cacheKey(config));
  }

  Future<void> _ensureUploadedInternal(SgtpConfig config, String cacheKey) async {
    final client = ServerV2MlsClient(
      rpcProvider: () => _connectionService.acquireRpc(config),
      sharedServerEvents: _connectionService.serverEvents,
    );
    await client.connect();
    await client.ensureSubscribedToEvents();

    final mls = MessengerMls.create();
    final privateKey = await config.identityKeyPair.extractPrivateKeyBytes();
    final clientId = _clientId(config);

    var restored = false;
    try {
      final snapshot = await _loadPersistedMlsState(config);
      if (snapshot != null && snapshot.isNotEmpty) {
        mls.restoreClientSync(snapshot);
        final restoredId = _map(mls.getClientIdSync());
        final restoredUser = (restoredId['user_id'] as String?)?.trim() ?? '';
        final restoredDevice =
            (restoredId['device_id'] as String?)?.trim() ?? '';
        if (restoredUser == clientId['user_id'] &&
            restoredDevice == clientId['device_id']) {
          restored = true;
        } else {
          _log.warning(
            'Ignoring shell MLS snapshot with mismatched client_id restoredUser={restoredUser} restoredDevice={restoredDevice}',
            parameters: {
              'restoredUser': restoredUser,
              'restoredDevice': restoredDevice,
            },
          );
        }
      }
    } catch (e, st) {
      _log.warning(
        'Failed to restore shell MLS state: {error}',
        parameters: {'error': e},
        error: e,
        stackTrace: st,
      );
    }

    if (!restored) {
      mls.createClientSync({
        'client_id': clientId,
        'device_signature_private_key': privateKey,
        'binding': {
          'client_id': clientId,
          'serialized_binding': config.myPublicKey,
          'account_signature': <int>[],
        },
        'identity_data': config.myPublicKey,
      });
    }

    final raw = _map(mls.createKeyPackagesSync(8));
    final generated = _asObjectList(raw['keypackages']);
    if (generated.isEmpty) {
      throw StateError('chat_core returned no key packages');
    }

    final expiresAt = DateTime.now().toUtc().add(const Duration(days: 30));
    await client.uploadKeyPackages(
      generated
          .map(
            (item) => KeyPackageDto(
              keyPackageBytes: _asBytes(item),
              isLastResort: false,
              expiresAtUs: expiresAt.microsecondsSinceEpoch,
            ),
          )
          .toList(),
    );

    try {
      mls.markKeyPackagesUploadedSync(raw);
    } catch (e, st) {
      _log.warning(
        'markKeyPackagesUploaded failed after shell upload: {error}',
        parameters: {'error': e},
        error: e,
        stackTrace: st,
      );
    }

    await _persistMlsState(config, mls);
    _uploadedKeys.add(cacheKey);
    _log.info(
      'Uploaded MLS key packages at shell level for account {accountId}',
      parameters: {'accountId': config.accountId ?? ''},
    );
  }

  Map<String, String> _clientId(SgtpConfig config) {
    final userId = _hex(config.myPublicKey).trim();
    return {
      'user_id': userId.isEmpty ? _hex(config.myPublicKey) : userId,
      'device_id': 'flutter-${_hex(config.myPublicKey).substring(0, 16)}',
    };
  }

  String _cacheKey(SgtpConfig config) {
    return '${config.serverAddr}|${config.accountId ?? ''}|${_hex(config.myPublicKey)}';
  }

  Future<Uint8List?> _loadPersistedMlsState(SgtpConfig config) async {
    if (kIsWeb) {
      return null;
    }
    try {
      final file = await _getMlsStateFile(config);
      if (file == null || !await file.exists()) {
        return null;
      }
      final bytes = await file.readAsBytes();
      return bytes.isEmpty ? null : Uint8List.fromList(bytes);
    } catch (_) {
      return null;
    }
  }

  Future<void> _persistMlsState(SgtpConfig config, MessengerMls mls) async {
    if (kIsWeb) {
      return;
    }
    try {
      final file = await _getMlsStateFile(config);
      if (file == null) {
        return;
      }
      final bytes = mls.exportClientStateSync();
      if (bytes.isEmpty) {
        return;
      }
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes, flush: true);
    } catch (e, st) {
      _log.warning(
        'Failed to persist shell MLS state: {error}',
        parameters: {'error': e},
        error: e,
        stackTrace: st,
      );
    }
  }

  Future<File?> _getMlsStateFile(SgtpConfig config) async {
    final docsDir = await getApplicationDocumentsDirectory();
    final accountId = (config.accountId ?? '').trim();
    final base = accountId.isEmpty
        ? Directory('${docsDir.path}/sgtp_mls')
        : Directory('${docsDir.path}/sgtp_accounts/$accountId/sgtp_mls');
    final key = _hex(config.myPublicKey);
    return File('${base.path}/client_state_${key.substring(0, 16)}.bin');
  }

  static Map<String, dynamic> _map(Object? value) =>
      Map<String, dynamic>.from((value as Map?) ?? const {});

  static List<Object?> _asObjectList(Object? value) {
    if (value is List) {
      return List<Object?>.from(value);
    }
    return const <Object?>[];
  }

  static Uint8List _asBytes(Object? value) {
    if (value is Uint8List) {
      return value;
    }
    if (value is List<int>) {
      return Uint8List.fromList(value);
    }
    if (value is List) {
      return Uint8List.fromList(value.cast<int>());
    }
    return Uint8List(0);
  }

  static String _hex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}
