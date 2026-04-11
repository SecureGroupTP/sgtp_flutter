import 'dart:async';
import 'dart:typed_data';

import 'package:web_socket_channel/web_socket_channel.dart';

import 'package:sgtp_flutter/core/network/i_protocol_transport.dart';

class WebSocketSgtpTransport implements IProtocolTransport {
  final String host;
  final int port;
  final bool useTls;
  final String? fakeSni;

  final StreamController<Uint8List> _inbound =
      StreamController<Uint8List>.broadcast();
  void Function(Uint8List)? _packetCallback;
  WebSocketChannel? _ws;
  StreamSubscription? _sub;

  WebSocketSgtpTransport({
    required this.host,
    required this.port,
    required this.useTls,
    this.fakeSni,
  });

  @override
  Stream<Uint8List> get inbound => _inbound.stream;

  @override
  bool get isConnected => _ws != null;

  @override
  void registerPacketCallback(void Function(Uint8List bytes) callback) {
    _packetCallback = callback;
  }

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
        Uint8List bytes;
        if (event is Uint8List) {
          bytes = event;
        } else if (event is List<int>) {
          bytes = Uint8List.fromList(event);
        } else {
          return;
        }
        _inbound.add(bytes);
        _packetCallback?.call(bytes);
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
