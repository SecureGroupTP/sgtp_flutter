import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'sgtp_transport.dart';

class WebSocketSgtpTransport implements SgtpTransport {
  final String host;
  final int port;
  final bool useTls;

  final StreamController<Uint8List> _inbound =
      StreamController<Uint8List>.broadcast();
  WebSocket? _ws;
  StreamSubscription? _sub;

  WebSocketSgtpTransport({
    required this.host,
    required this.port,
    required this.useTls,
  });

  @override
  Stream<Uint8List> get inbound => _inbound.stream;

  @override
  bool get isConnected => _ws != null;

  @override
  Future<void> connect() async {
    if (_ws != null) return;
    final scheme = useTls ? 'wss' : 'ws';
    final uri = Uri.parse('$scheme://$host:$port/');
    final ws = await WebSocket.connect(uri.toString());
    _ws = ws;
    _sub = ws.listen(
      (event) {
        if (event is List<int>) {
          _inbound.add(Uint8List.fromList(event));
        }
      },
      onError: (e, st) => _inbound.addError(e, st),
      onDone: () => _inbound.close(),
      cancelOnError: false,
    );
  }

  @override
  Future<void> send(Uint8List bytes) async {
    final ws = _ws;
    if (ws == null) throw StateError('Not connected');
    ws.add(bytes);
  }

  @override
  Future<void> close() async {
    final ws = _ws;
    _ws = null;
    try {
      await _sub?.cancel();
    } catch (_) {}
    _sub = null;
    try {
      await ws?.close();
    } catch (_) {}
    if (!_inbound.isClosed) {
      await _inbound.close();
    }
  }
}

