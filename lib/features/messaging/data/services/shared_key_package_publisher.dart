import 'package:sgtp_flutter/core/app_log.dart';
import 'package:sgtp_flutter/core/network/rpc_models/mls_rpc_models.dart';
import 'package:sgtp_flutter/core/network/sgtp_connection_service.dart';
import 'package:sgtp_flutter/features/messaging/data/services/openmls_runtime.dart';
import 'package:sgtp_flutter/features/messaging/data/services/server_v2_mls_client.dart';
import 'package:sgtp_flutter/features/messaging/domain/entities/sgtp_config.dart';
import 'package:sgtp_flutter/features/messaging/domain/repositories/key_package_publisher.dart';

class SharedKeyPackagePublisher implements KeyPackagePublisher {
  SharedKeyPackagePublisher({
    required SgtpConnectionService connectionService,
    required OpenMlsRuntimeFactory openMlsRuntimeFactory,
  })  : _connectionService = connectionService,
        _openMlsRuntimeFactory = openMlsRuntimeFactory;

  final SgtpConnectionService _connectionService;
  final OpenMlsRuntimeFactory _openMlsRuntimeFactory;
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
    final runtime = await _openMlsRuntimeFactory.create(config);
    final generated = await runtime.createKeyPackages(8);
    if (generated.isEmpty) {
      throw StateError('openmls returned no key packages');
    }

    final expiresAt = DateTime.now().toUtc().add(const Duration(days: 30));
    try {
      await client.uploadKeyPackages(
        generated
            .map(
              (item) => KeyPackageDto(
                keyPackageBytes: item,
                isLastResort: false,
                expiresAtUs: expiresAt.microsecondsSinceEpoch,
              ),
            )
            .toList(),
      );
      _uploadedKeys.add(cacheKey);
      _log.info(
        'Uploaded MLS key packages at shell level for account {accountId}',
        parameters: {'accountId': config.accountId ?? ''},
      );
    } finally {
      await runtime.close();
    }
  }

  String _cacheKey(SgtpConfig config) {
    return '${config.serverAddr}|${config.accountId ?? ''}|${_hex(config.myPublicKey)}';
  }

  static String _hex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}
