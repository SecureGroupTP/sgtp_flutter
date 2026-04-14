import 'dart:async';
import 'dart:typed_data';

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
  final Set<String> _uploadedKeys = <String>{};
  final Map<String, Future<void>> _inFlight = <String, Future<void>>{};

  @override
  Future<void> ensureUploaded(SgtpConfig config) async {
    final cacheKey = _cacheKey(config);
    if (_uploadedKeys.contains(cacheKey)) {
      return;
    }
    final pending = _inFlight[cacheKey];
    if (pending != null) {
      await pending;
      return;
    }
    final future = _upload(config, cacheKey);
    _inFlight[cacheKey] = future;
    try {
      await future;
    } finally {
      if (identical(_inFlight[cacheKey], future)) {
        _inFlight.remove(cacheKey);
      }
    }
  }

  @override
  void invalidateForConfig(SgtpConfig config) {
    _uploadedKeys.remove(_cacheKey(config));
  }

  Future<void> _upload(SgtpConfig config, String cacheKey) async {
    MessengerMls? mls;
    try {
      await _connectionService.configure(config);
      final client = ServerV2MlsClient(
        rpcProvider: _connectionService.ensureConnected,
        sharedServerEvents: _connectionService.serverEvents,
      );
      await client.connect();

      mls = await _createMlsClient(config);
      final raw = _map(mls.createKeyPackagesSync(8));
      final generated = _asObjectList(raw['keypackages']);
      if (generated.isEmpty) {
        throw StateError('chat_core returned no key packages');
      }
      final expiresAt = DateTime.now().toUtc().add(const Duration(days: 30));
      await client.uploadKeyPackages(
        generated
            .map((item) => KeyPackageDto(
                  keyPackageBytes: _asBytes(item),
                  isLastResort: false,
                  expiresAtUs: expiresAt.microsecondsSinceEpoch,
                ))
            .toList(),
      );
      _uploadedKeys.add(cacheKey);
      _log.info(
        'Uploaded MLS key packages for app session {server}',
        parameters: {'server': config.serverAddr},
      );
    } catch (e, st) {
      _log.warning(
        'uploadKeyPackages failed at shell startup: {error}',
        parameters: {'error': e},
        error: e,
        stackTrace: st,
      );
      rethrow;
    } finally {
      mls?.close();
    }
  }

  Future<MessengerMls> _createMlsClient(SgtpConfig config) async {
    final privateKey = await config.identityKeyPair.extractPrivateKeyBytes();
    final userId = (config.accountId ?? config.nodeId ?? _hex(config.myPublicKey))
        .trim();
    final deviceId = 'flutter-${_hex(config.myPublicKey).substring(0, 16)}';
    final clientId = {
      'user_id': userId.isEmpty ? _hex(config.myPublicKey) : userId,
      'device_id': deviceId,
    };
    final mls = MessengerMls.create();
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
    return mls;
  }

  String _cacheKey(SgtpConfig config) {
    final account = (config.accountId ?? '').trim();
    final node = (config.nodeId ?? '').trim();
    final identity = _hex(config.myPublicKey);
    return '${config.serverAddr.trim().toLowerCase()}|$account|$node|$identity';
  }

  Map<String, dynamic> _map(Object? value) {
    if (value is Map<String, dynamic>) return value;
    if (value is Map) {
      return value.map((key, item) => MapEntry('$key', item));
    }
    return const <String, dynamic>{};
  }

  List<Object?> _asObjectList(Object? value) {
    if (value is List) return value.cast<Object?>();
    return const <Object?>[];
  }

  Uint8List _asBytes(Object? value) {
    if (value is Uint8List) return value;
    if (value is List<int>) return Uint8List.fromList(value);
    if (value is List) {
      return Uint8List.fromList(value.map((e) => (e as num).toInt()).toList());
    }
    return Uint8List(0);
  }
}

String _hex(Uint8List bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
