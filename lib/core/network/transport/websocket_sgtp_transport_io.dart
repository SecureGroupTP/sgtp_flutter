import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:sgtp_flutter/core/app_log.dart';
import 'package:sgtp_flutter/core/network/i_protocol_transport.dart';

final _log = AppLog('WebSocketSgtpTransport');

class WebSocketSgtpTransport implements IProtocolTransport {
  final String host;
  final int port;
  final bool useTls;
  final String? fakeSni;

  final StreamController<Uint8List> _inbound =
      StreamController<Uint8List>.broadcast();
  void Function(Uint8List)? _packetCallback;

  Socket? _socket;
  StreamSubscription? _sub;
  Timer? _pingTimer;

  final _buf = <int>[];
  bool _upgraded = false;
  final _upgradeCompleter = Completer<void>();

  int _frmState = 0;
  int _frmOpcode = 0;
  int _frmPayloadLen = 0;
  int _frmExtLenBytes = 0;
  int _frmExtLenRead = 0;
  Uint8List? _frmPayload;
  int _frmPayloadRead = 0;

  static final _rng = Random.secure();

  WebSocketSgtpTransport({
    required this.host,
    required this.port,
    required this.useTls,
    this.fakeSni,
  });

  @override
  Stream<Uint8List> get inbound => _inbound.stream;

  @override
  bool get isConnected => _socket != null;

  @override
  void registerPacketCallback(void Function(Uint8List bytes) callback) {
    _packetCallback = callback;
  }

  @override
  Future<void> connect() async {
    if (_socket != null) return;
    final tlsSni = (fakeSni ?? '').trim();
    _log.debug('Connecting WS to {host}:{port} (tls={useTls}, sni={sni})',
        parameters: {
          'host': host,
          'port': port,
          'useTls': useTls,
          'sni': tlsSni.isEmpty ? host : tlsSni
        });

    final sock =
        useTls ? await _connectTlsSocket() : await Socket.connect(host, port);

    _socket = sock;

    _sub = sock.listen(
      _onRawData,
      onError: (e, st) {
        _socket = null;
        _stopPingTimer();
        if (!_upgradeCompleter.isCompleted) {
          _upgradeCompleter.completeError(e, st);
        }
        if (!_inbound.isClosed) _inbound.addError(e, st);
      },
      onDone: () {
        _socket = null;
        _stopPingTimer();
        if (!_upgradeCompleter.isCompleted) {
          _upgradeCompleter
              .completeError(StateError('Socket closed during WS upgrade'));
        }
        if (!_inbound.isClosed) _inbound.close();
      },
      cancelOnError: false,
    );

    final key = _generateWsKey();
    sock.write(
      'GET /api/v1/client HTTP/1.1\r\n'
      'Host: $host:$port\r\n'
      'Upgrade: websocket\r\n'
      'Connection: Upgrade\r\n'
      'Sec-WebSocket-Key: $key\r\n'
      'Sec-WebSocket-Version: 13\r\n'
      '\r\n',
    );
    await sock.flush();

    await _upgradeCompleter.future;
    _startPingTimer();
  }

  Future<SecureSocket> _connectTlsSocket() async {
    final tlsServerName = (fakeSni ?? '').trim();
    if (tlsServerName.isNotEmpty &&
        tlsServerName.toLowerCase() != host.toLowerCase()) {
      final raw = await Socket.connect(host, port);
      return SecureSocket.secure(
        raw,
        host: tlsServerName,
      );
    }
    return SecureSocket.connect(host, port);
  }

  @override
  Future<void> send(Uint8List bytes) async {
    final sock = _socket;
    if (sock == null) throw StateError('Not connected');
    sock.add(_encodeFrame(bytes));
    await sock.flush();
  }

  @override
  Future<void> close() async {
    final sock = _socket;
    _socket = null;
    _stopPingTimer();
    try {
      await _sub?.cancel();
    } catch (_) {}
    _sub = null;
    try {
      if (sock != null) {
        sock.add(_encodeCloseFrame());
        await sock.flush();
        await sock.close();
      }
    } catch (_) {}
    if (!_inbound.isClosed) await _inbound.close();
  }

  void _onRawData(List<int> data) {
    _buf.addAll(data);
    if (!_upgraded) {
      _tryCompleteUpgrade();
    } else {
      _parseFrames();
    }
  }

  void _tryCompleteUpgrade() {
    final len = _buf.length;
    for (int i = 0; i <= len - 4; i++) {
      if (_buf[i] == 0x0D &&
          _buf[i + 1] == 0x0A &&
          _buf[i + 2] == 0x0D &&
          _buf[i + 3] == 0x0A) {
        final header = latin1.decode(_buf.sublist(0, i + 4));
        _buf.removeRange(0, i + 4);

        if (!header.contains('101')) {
          _upgradeCompleter
              .completeError(StateError('WS upgrade failed:\n$header'));
          return;
        }

        _upgraded = true;
        _upgradeCompleter.complete();

        if (_buf.isNotEmpty) _parseFrames();
        return;
      }
    }
  }

  void _parseFrames() {
    int pos = 0;
    final buf = _buf;

    while (pos < buf.length) {
      if (_frmState == 0) {
        if (buf.length - pos < 2) break;

        final b0 = buf[pos];
        final b1 = buf[pos + 1];
        pos += 2;

        _frmOpcode = b0 & 0x0F;
        final lenByte = b1 & 0x7F;

        if (lenByte <= 125) {
          _frmPayloadLen = lenByte;
          _frmExtLenBytes = 0;
          _frmPayload = Uint8List(_frmPayloadLen);
          _frmPayloadRead = 0;
          _frmState = 2;
        } else if (lenByte == 126) {
          _frmExtLenBytes = 2;
          _frmExtLenRead = 0;
          _frmPayloadLen = 0;
          _frmState = 1;
        } else {
          _frmExtLenBytes = 8;
          _frmExtLenRead = 0;
          _frmPayloadLen = 0;
          _frmState = 1;
        }
        continue;
      }

      if (_frmState == 1) {
        while (_frmExtLenRead < _frmExtLenBytes && pos < buf.length) {
          _frmPayloadLen = (_frmPayloadLen << 8) | buf[pos];
          pos++;
          _frmExtLenRead++;
        }
        if (_frmExtLenRead < _frmExtLenBytes) break;

        _frmPayload = Uint8List(_frmPayloadLen);
        _frmPayloadRead = 0;
        _frmState = 2;
        continue;
      }

      if (_frmState == 2) {
        final need = _frmPayloadLen - _frmPayloadRead;
        final have = buf.length - pos;
        final take = need < have ? need : have;

        if (take > 0) {
          final dst = _frmPayload!;
          for (int i = 0; i < take; i++) {
            dst[_frmPayloadRead + i] = buf[pos + i];
          }
          _frmPayloadRead += take;
          pos += take;
        }

        if (_frmPayloadRead == _frmPayloadLen) {
          _dispatchFrame(_frmOpcode, _frmPayload!);
          _frmState = 0;
          _frmPayload = null;
        }
        continue;
      }

      break;
    }

    if (pos > 0) buf.removeRange(0, pos);
  }

  void _dispatchFrame(int opcode, Uint8List payload) {
    switch (opcode) {
      case 0x0:
      case 0x2:
      case 0x1:
        if (!_inbound.isClosed) _inbound.add(payload);
        _packetCallback?.call(payload);
        break;
      case 0x9:
        final sock = _socket;
        if (sock != null && payload.length <= 125) {
          sock.add(_encodePong(payload));
          sock.flush();
        }
        break;
      case 0xA:
        // pong
        break;
      case 0x8:
        close();
        break;
    }
  }

  static Uint8List _encodeFrame(Uint8List payload) {
    final len = payload.length;
    final mask = _randomMask();

    final int extLen;
    final int headerLen;
    if (len <= 125) {
      extLen = 0;
      headerLen = 2 + 4;
    } else if (len <= 0xFFFF) {
      extLen = 2;
      headerLen = 4 + 4;
    } else {
      extLen = 8;
      headerLen = 10 + 4;
    }

    final frame = Uint8List(headerLen + len);
    int off = 0;

    frame[off++] = 0x82;
    if (extLen == 0) {
      frame[off++] = 0x80 | len;
    } else if (extLen == 2) {
      frame[off++] = 0x80 | 126;
      frame[off++] = (len >> 8) & 0xFF;
      frame[off++] = len & 0xFF;
    } else {
      frame[off++] = 0x80 | 127;
      for (int i = 7; i >= 0; i--) {
        frame[off++] = (len >> (i * 8)) & 0xFF;
      }
    }

    frame[off++] = mask[0];
    frame[off++] = mask[1];
    frame[off++] = mask[2];
    frame[off++] = mask[3];

    for (int i = 0; i < len; i++) {
      frame[off + i] = payload[i] ^ mask[i & 3];
    }

    return frame;
  }

  static Uint8List _encodeCloseFrame() {
    final mask = _randomMask();
    return Uint8List.fromList([0x88, 0x80, mask[0], mask[1], mask[2], mask[3]]);
  }

  static Uint8List _encodePong(Uint8List pingPayload) {
    final mask = _randomMask();
    final len = pingPayload.length;
    final frame = Uint8List(2 + 4 + len);
    frame[0] = 0x8A;
    frame[1] = 0x80 | len;
    frame[2] = mask[0];
    frame[3] = mask[1];
    frame[4] = mask[2];
    frame[5] = mask[3];
    for (int i = 0; i < len; i++) {
      frame[6 + i] = pingPayload[i] ^ mask[i & 3];
    }
    return frame;
  }

  void _startPingTimer() {
    _pingTimer ??= Timer.periodic(const Duration(seconds: 15), (_) {
      final sock = _socket;
      if (sock == null) return;
      try {
        sock.add(_encodePing(_randomPingPayload()));
        sock.flush();
      } catch (_) {}
    });
  }

  void _stopPingTimer() {
    _pingTimer?.cancel();
    _pingTimer = null;
  }

  static Uint8List _randomPingPayload() {
    // Small payload helps some intermediaries keep the connection open.
    final now = DateTime.now().microsecondsSinceEpoch;
    return Uint8List.fromList([
      (now >> 24) & 0xFF,
      (now >> 16) & 0xFF,
      (now >> 8) & 0xFF,
      now & 0xFF,
    ]);
  }

  static Uint8List _encodePing(Uint8List payload) {
    final mask = _randomMask();
    final len = payload.length;
    final frame = Uint8List(2 + 4 + len);
    frame[0] = 0x89;
    frame[1] = 0x80 | len;
    frame[2] = mask[0];
    frame[3] = mask[1];
    frame[4] = mask[2];
    frame[5] = mask[3];
    for (int i = 0; i < len; i++) {
      frame[6 + i] = payload[i] ^ mask[i & 3];
    }
    return frame;
  }

  static List<int> _randomMask() => [
        _rng.nextInt(256),
        _rng.nextInt(256),
        _rng.nextInt(256),
        _rng.nextInt(256),
      ];

  static String _generateWsKey() {
    final bytes = Uint8List(16);
    for (int i = 0; i < 16; i++) {
      bytes[i] = _rng.nextInt(256);
    }
    return base64.encode(bytes);
  }
}
