import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'package:sgtp_flutter/core/network/i_protocol_transport.dart';

/// Stateless HTTP transport for CBOR-RPC: each [send] is a single POST to
/// `/rpc`, and the response bytes are immediately delivered to the registered
/// packet callback. No session, no polling.
class HttpProtocolTransport implements IProtocolTransport {
  final String host;
  final int port;
  final bool useTls;

  final StreamController<Uint8List> _inbound =
      StreamController<Uint8List>.broadcast();
  void Function(Uint8List)? _packetCallback;
  bool _connected = false;

  late final http.Client _httpClient;

  HttpProtocolTransport({
    required this.host,
    required this.port,
    required this.useTls,
  }) {
    _httpClient = http.Client();
  }

  Uri get _rpcUri => Uri(
        scheme: useTls ? 'https' : 'http',
        host: host,
        port: port,
        path: '/rpc',
      );

  @override
  bool get isConnected => _connected;

  @override
  Stream<Uint8List> get inbound => _inbound.stream;

  @override
  void registerPacketCallback(void Function(Uint8List bytes) callback) {
    _packetCallback = callback;
  }

  @override
  Future<void> connect() async {
    _connected = true;
  }

  @override
  Future<void> close() async {
    _connected = false;
    _httpClient.close();
    if (!_inbound.isClosed) await _inbound.close();
  }

  @override
  Future<void> send(Uint8List bytes) async {
    if (!_connected) throw StateError('Not connected');
    final res = await _httpClient.post(
      _rpcUri,
      headers: {
        'Content-Type': 'application/cbor',
        'Accept': 'application/cbor',
      },
      body: bytes,
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw StateError('RPC HTTP error ${res.statusCode}');
    }
    final responseBytes = res.bodyBytes;
    if (responseBytes.isNotEmpty) {
      _inbound.add(responseBytes);
      _packetCallback?.call(responseBytes);
    }
  }
}
