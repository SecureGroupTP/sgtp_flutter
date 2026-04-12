import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:http2/http2.dart';

import 'package:sgtp_flutter/core/app_logger.dart';
import 'package:sgtp_flutter/core/network/i_protocol_transport.dart';

const _tag = 'H2';

/// HTTP/2 persistent transport for CBOR-RPC.
///
/// Maintains a single connection. Each [send] opens a new HTTP/2 stream
/// (POST /api/v1/client), delivers the response via [_packetCallback], then
/// closes the stream. Server-pushed streams on each request are also
/// delivered via the same callback so event notifications work transparently.
class HttpProtocolTransport implements IProtocolTransport {
  final String host;
  final int port;
  final bool useTls;

  final StreamController<Uint8List> _inbound =
      StreamController<Uint8List>.broadcast();
  void Function(Uint8List)? _packetCallback;

  Socket? _socket;
  ClientTransportConnection? _connection;

  HttpProtocolTransport({
    required this.host,
    required this.port,
    required this.useTls,
  });

  @override
  bool get isConnected => _connection?.isOpen ?? false;

  @override
  Stream<Uint8List> get inbound => _inbound.stream;

  @override
  void registerPacketCallback(void Function(Uint8List bytes) callback) {
    _packetCallback = callback;
  }

  @override
  Future<void> connect() async {
    if (_connection?.isOpen ?? false) return;

    final Socket socket;
    if (useTls) {
      socket = await SecureSocket.connect(
        host,
        port,
        supportedProtocols: ['h2'],
        onBadCertificate: (cert) {
          AppLogger.e(
            'TLS cert rejected: subject="${cert.subject}"',
            tag: _tag,
          );
          return false;
        },
      );
    } else {
      socket = await Socket.connect(host, port);
    }

    _socket = socket;
    _connection = ClientTransportConnection.viaSocket(
      socket,
      settings: const ClientSettings(allowServerPushes: true),
    );

    AppLogger.d('HTTP/2 connected to $host:$port (tls=$useTls)', tag: _tag);
  }

  @override
  Future<void> send(Uint8List bytes) async {
    final conn = _connection;
    if (conn == null || !conn.isOpen) throw StateError('Not connected');

    final stream = conn.makeRequest(
      [
        Header.ascii(':method', 'POST'),
        Header.ascii(':path', '/api/v1/client'),
        Header.ascii(':scheme', useTls ? 'https' : 'http'),
        Header.ascii(':authority', '$host:$port'),
        Header.ascii('content-type', 'application/cbor'),
        Header.ascii('accept', 'application/cbor'),
      ],
      endStream: false,
    );

    // Handle server pushes on this request stream.
    stream.peerPushes.listen(
      (push) => _drainPushedStream(push.stream),
      onError: (e) => AppLogger.w('H2 server push error: $e', tag: _tag),
    );

    stream.sendData(bytes, endStream: true);

    final buf = <int>[];
    await for (final msg in stream.incomingMessages) {
      if (msg is DataStreamMessage) {
        buf.addAll(msg.bytes);
      }
    }

    if (buf.isNotEmpty) {
      _deliver(Uint8List.fromList(buf));
    }
  }

  void _drainPushedStream(ClientTransportStream pushed) {
    final buf = <int>[];
    pushed.incomingMessages.listen(
      (msg) {
        if (msg is DataStreamMessage) {
          buf.addAll(msg.bytes);
          if (msg.endStream) _deliver(Uint8List.fromList(buf));
        }
      },
      onError: (e) => AppLogger.w('H2 push data error: $e', tag: _tag),
    );
  }

  void _deliver(Uint8List bytes) {
    if (!_inbound.isClosed) _inbound.add(bytes);
    _packetCallback?.call(bytes);
  }

  @override
  Future<void> close() async {
    try {
      await _connection?.terminate();
    } catch (_) {}
    _connection = null;
    try {
      await _socket?.close();
    } catch (_) {}
    _socket = null;
    if (!_inbound.isClosed) await _inbound.close();
  }
}
