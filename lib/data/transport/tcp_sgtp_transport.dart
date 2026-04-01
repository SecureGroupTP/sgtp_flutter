import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'sgtp_transport.dart';

class TcpSgtpTransport implements SgtpTransport {
  final String host;
  final int port;
  final bool useTls;

  final StreamController<Uint8List> _inbound =
      StreamController<Uint8List>.broadcast();
  Socket? _socket;
  StreamSubscription? _sub;

  TcpSgtpTransport({
    required this.host,
    required this.port,
    required this.useTls,
  });

  @override
  Stream<Uint8List> get inbound => _inbound.stream;

  @override
  bool get isConnected => _socket != null;

  @override
  Future<void> connect() async {
    if (_socket != null) return;
    final s = useTls
        ? await SecureSocket.connect(host, port)
        : await Socket.connect(host, port);

    // Reduce latency: send small frames immediately without Nagle buffering.
    try {
      s.setOption(SocketOption.tcpNoDelay, true);
    } catch (_) {}

    // Best-effort keepalive.
    try {
      s.setRawOption(RawSocketOption(
        RawSocketOption.levelSocket,
        9, // SO_KEEPALIVE
        Uint8List.fromList([1, 0, 0, 0]),
      ));
    } catch (_) {}

    _socket = s;
    _sub = s.listen(
      (data) => _inbound.add(Uint8List.fromList(data)),
      onError: (e, st) => _inbound.addError(e, st),
      onDone: () => _inbound.close(),
      cancelOnError: false,
    );
  }

  @override
  Future<void> send(Uint8List bytes) async {
    final s = _socket;
    if (s == null) throw StateError('Not connected');
    s.add(bytes);
    await s.flush();
  }

  @override
  Future<void> close() async {
    final s = _socket;
    _socket = null;
    try {
      await _sub?.cancel();
    } catch (_) {}
    _sub = null;
    try {
      await s?.close();
    } catch (_) {
      s?.destroy();
    }
    if (!_inbound.isClosed) {
      await _inbound.close();
    }
  }
}

