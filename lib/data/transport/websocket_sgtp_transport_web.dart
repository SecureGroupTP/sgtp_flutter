import 'dart:async';
import 'dart:typed_data';

import 'package:web_socket_channel/web_socket_channel.dart';

import 'sgtp_transport.dart';

class WebSocketSgtpTransport implements SgtpTransport {
  final String host;
  final int port;
  final bool useTls;

  final StreamController<Uint8List> _inbound =
      StreamController<Uint8List>.broadcast();
  WebSocketChannel? _ws;
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
    final ws = WebSocketChannel.connect(uri);
    await ws.ready;
    _ws = ws;
    _sub = ws.stream.listen(
      (event) {
        if (event is Uint8List) {
          _inbound.add(event);
          return;
        }
        if (event is List<int>) {
          _inbound.add(Uint8List.fromList(event));
        }
      },
      onError: (e, st) => _inbound.addError(e, st),
      onDone: () {
        if (!_inbound.isClosed) {
          _inbound.close();
        }
      },
      cancelOnError: false,
    );
  }

  @override
  Future<void> send(Uint8List bytes) async {
    final ws = _ws;
    if (ws == null) throw StateError('Not connected');
    ws.sink.add(bytes);
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
      await ws?.sink.close();
    } catch (_) {}
    if (!_inbound.isClosed) {
      await _inbound.close();
    }
  }
}
