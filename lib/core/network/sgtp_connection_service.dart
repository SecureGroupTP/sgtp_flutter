import 'dart:async';

import 'package:sgtp_flutter/core/network/events/connection_events.dart';
import 'package:sgtp_flutter/core/network/i_protocol_transport.dart';
import 'package:sgtp_flutter/core/network/sgtp_rpc_client.dart';
import 'package:sgtp_flutter/core/network/transport/http_protocol_transport.dart';
import 'package:sgtp_flutter/core/network/transport/tcp_sgtp_transport.dart';
import 'package:sgtp_flutter/core/network/transport/websocket_sgtp_transport.dart';
import 'package:sgtp_flutter/core/sgtp_server_options.dart';
import 'package:sgtp_flutter/core/sgtp_transport.dart';
import 'package:sgtp_flutter/features/messaging/data/transport/server_discovery.dart';
import 'package:sgtp_flutter/features/messaging/domain/entities/sgtp_config.dart';

class SgtpConnectionService {
  final _events = StreamController<SgtpConnectionStateChanged>.broadcast();

  SgtpConfig? _config;
  SgtpRpcClient? _rpc;
  IProtocolTransport? _transport;
  Future<SgtpRpcClient>? _connectFuture;
  SgtpConnectionStateChanged _state =
      const SgtpConnectionStateChanged(status: SgtpConnectionStatus.disconnected);

  Stream<SgtpConnectionStateChanged> get events => _events.stream;
  SgtpConnectionStatus get status => _state.status;
  String? get lastError => _state.errorMessage;
  bool get isConnected => _transport?.isConnected == true;

  Future<void> configure(SgtpConfig config) async {
    if (_config != null && _isSameConnection(_config!, config)) {
      _config = config;
      return;
    }
    await disconnect();
    _config = config;
  }

  Future<SgtpRpcClient> acquireRpc(SgtpConfig config) async {
    await configure(config);
    return ensureConnected();
  }

  Future<SgtpRpcClient> ensureConnected() async {
    if (_rpc != null && _transport?.isConnected == true) {
      if (_state.status != SgtpConnectionStatus.connected) {
        _emit(const SgtpConnectionStateChanged(
          status: SgtpConnectionStatus.connected,
        ));
      }
      return _rpc!;
    }
    final pending = _connectFuture;
    if (pending != null) return pending;
    final future = _open();
    _connectFuture = future;
    try {
      return await future;
    } finally {
      if (identical(_connectFuture, future)) {
        _connectFuture = null;
      }
    }
  }

  Future<void> disconnect() async {
    _connectFuture = null;
    final transport = _transport;
    _transport = null;
    _rpc = null;
    if (transport != null) {
      try {
        await transport.close();
      } catch (_) {}
    }
    _emit(const SgtpConnectionStateChanged(
      status: SgtpConnectionStatus.disconnected,
    ));
  }

  Future<SgtpRpcClient> _open() async {
    final config = _config;
    if (config == null) {
      throw StateError('SGTP connection is not configured');
    }
    _emit(const SgtpConnectionStateChanged(
      status: SgtpConnectionStatus.connecting,
    ));
    try {
      final parsed = _parseHostPortOrThrow(config.serverAddr);
      final endpoint = await _resolveEndpoint(config, parsed);
      final transport = _buildTransport(
        host: endpoint.host,
        port: endpoint.port,
        family: SgtpTransportFamilyCodec.resolve(config.transport),
        tls: config.useTls,
        fakeSni: config.fakeSni,
      );
      await transport.connect();
      final rpc = SgtpRpcClient(transport);
      final authError = await rpc.authenticate(
        config.myPublicKey,
        config.identityKeyPair,
        deviceId: 'flutter-${_pubHex(config).substring(0, 16)}',
      );
      if (authError != null) {
        throw StateError(authError);
      }
      _transport = transport;
      _rpc = rpc;
      _emit(const SgtpConnectionStateChanged(
        status: SgtpConnectionStatus.connected,
      ));
      return rpc;
    } catch (e) {
      _emit(SgtpConnectionStateChanged(
        status: SgtpConnectionStatus.error,
        errorMessage: '$e',
      ));
      rethrow;
    }
  }

  Future<({String host, int port})> _resolveEndpoint(
    SgtpConfig config,
    ({String host, int? explicitPort}) parsed,
  ) async {
    final family = SgtpTransportFamilyCodec.resolve(config.transport);
    final tls = config.useTls;
    final result = await SgtpServerDiscovery.discover(
      parsed.host,
      preferredPort: parsed.explicitPort,
      preferredTls: tls,
    );
    final opts = result.opts;
    if (!opts.supports(family, tls: tls)) {
      throw StateError(
        'Selected transport (${family.name}, tls=$tls) not supported by server.',
      );
    }
    final port = _selectPort(
      opts: opts,
      family: family,
      tls: tls,
    );
    return (host: parsed.host, port: port);
  }

  int _selectPort({
    required SgtpServerOptions opts,
    required SgtpTransportFamily family,
    required bool tls,
  }) {
    final port = opts.portFor(family, tls: tls);
    if (port <= 0) {
      throw StateError(
        'Server discovery returned invalid port for ${family.name} (tls=$tls).',
      );
    }
    return port;
  }

  ({String host, int? explicitPort}) _parseHostPortOrThrow(String raw) {
    final s = raw
        .trim()
        .replaceAll(RegExp(r'^https?://', caseSensitive: false), '')
        .replaceAll(RegExp(r'^wss?://', caseSensitive: false), '')
        .trim();
    if (s.isEmpty) {
      throw ArgumentError('Empty server address');
    }
    if (s.startsWith('[')) {
      final end = s.indexOf(']');
      if (end <= 1) {
        throw ArgumentError('Invalid IPv6 address: $raw');
      }
      final host = s.substring(1, end);
      final rest = s.substring(end + 1);
      final port = rest.startsWith(':') ? int.tryParse(rest.substring(1)) : null;
      return (host: host, explicitPort: port);
    }
    final index = s.lastIndexOf(':');
    if (index <= 0 || index == s.length - 1 || s.substring(0, index).contains(':')) {
      return (host: s, explicitPort: null);
    }
    return (
      host: s.substring(0, index),
      explicitPort: int.tryParse(s.substring(index + 1)),
    );
  }

  IProtocolTransport _buildTransport({
    required String host,
    required int port,
    required SgtpTransportFamily family,
    required bool tls,
    String? fakeSni,
  }) {
    switch (family) {
      case SgtpTransportFamily.tcp:
        return TcpSgtpTransport(
          host: host,
          port: port,
          useTls: tls,
          fakeSni: fakeSni,
        );
      case SgtpTransportFamily.websocket:
        return WebSocketSgtpTransport(
          host: host,
          port: port,
          useTls: tls,
          fakeSni: fakeSni,
        );
      case SgtpTransportFamily.http:
        return HttpProtocolTransport(
          host: host,
          port: port,
          useTls: tls,
        );
    }
  }

  bool _isSameConnection(SgtpConfig a, SgtpConfig b) {
    return a.serverAddr.trim() == b.serverAddr.trim() &&
        a.transport == b.transport &&
        a.useTls == b.useTls &&
        a.fakeSni.trim() == b.fakeSni.trim() &&
        _pubHex(a) == _pubHex(b);
  }

  String _pubHex(SgtpConfig config) =>
      config.myPublicKey.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  void _emit(SgtpConnectionStateChanged event) {
    _state = event;
    if (!_events.isClosed) {
      _events.add(event);
    }
  }
}
