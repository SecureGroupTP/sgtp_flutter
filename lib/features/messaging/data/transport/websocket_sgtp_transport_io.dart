import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:sgtp_flutter/features/messaging/data/transport/sgtp_transport.dart';

class WebSocketSgtpTransport implements SgtpTransport {
  final String host;
  final int port;
  final bool useTls;

  final StreamController<Uint8List> _inbound =
      StreamController<Uint8List>.broadcast();

  Socket? _socket;
  StreamSubscription? _sub;

  // Single buffer for all incoming bytes (upgrade headers + WS frames)
  final _buf = <int>[];
  bool _upgraded = false;
  final _upgradeCompleter = Completer<void>();

  // WS frame decode state machine
  //   0 = waiting for first 2 header bytes
  //   1 = waiting for extended-length bytes
  //   2 = accumulating payload
  int _frmState = 0;
  int _frmOpcode = 0;
  int _frmPayloadLen = 0;
  int _frmExtLenBytes = 0; // 0, 2, or 8
  int _frmExtLenRead = 0;
  Uint8List? _frmPayload; // preallocated to _frmPayloadLen
  int _frmPayloadRead = 0;

  static final _rng = Random.secure();

  WebSocketSgtpTransport({
    required this.host,
    required this.port,
    required this.useTls,
  });

  @override
  Stream<Uint8List> get inbound => _inbound.stream;

  @override
  bool get isConnected => _socket != null;

  // ── connect ───────────────────────────────────────────────────────────────

  @override
  Future<void> connect() async {
    if (_socket != null) return;

    final sock = useTls
        ? await SecureSocket.connect(host, port,
            onBadCertificate: (_) => true)
        : await Socket.connect(host, port);

    _socket = sock;

    // Subscribe once — handles both the upgrade response and WS frames.
    _sub = sock.listen(
      _onRawData,
      onError: (e, st) {
        if (!_upgradeCompleter.isCompleted) {
          _upgradeCompleter.completeError(e, st);
        }
        if (!_inbound.isClosed) _inbound.addError(e, st);
      },
      onDone: () {
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
      'GET / HTTP/1.1\r\n'
      'Host: $host:$port\r\n'
      'Upgrade: websocket\r\n'
      'Connection: Upgrade\r\n'
      'Sec-WebSocket-Key: $key\r\n'
      'Sec-WebSocket-Version: 13\r\n'
      '\r\n',
    );
    await sock.flush();

    await _upgradeCompleter.future;
  }

  // ── send ──────────────────────────────────────────────────────────────────

  @override
  Future<void> send(Uint8List bytes) async {
    final sock = _socket;
    if (sock == null) throw StateError('Not connected');
    sock.add(_encodeFrame(bytes));
    await sock.flush(); // real backpressure: blocks until OS accepts the data
  }

  // ── close ─────────────────────────────────────────────────────────────────

  @override
  Future<void> close() async {
    final sock = _socket;
    _socket = null;
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

  // ── raw data handler ──────────────────────────────────────────────────────

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

  // ── WS frame parser ───────────────────────────────────────────────────────

  void _parseFrames() {
    int pos = 0;
    final buf = _buf;

    while (pos < buf.length) {
      if (_frmState == 0) {
        // Need 2 bytes for the base header
        if (buf.length - pos < 2) break;

        final b0 = buf[pos];
        final b1 = buf[pos + 1];
        pos += 2;

        _frmOpcode = b0 & 0x0F;
        // b0 bit7 = FIN (we ignore continuation frames — SGTP doesn't fragment)
        final lenByte = b1 & 0x7F;
        // b1 bit7 = MASK (server→client must NOT mask, so we ignore)

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
        // Read extended length bytes one at a time (at most 8 bytes total)
        while (_frmExtLenRead < _frmExtLenBytes && pos < buf.length) {
          _frmPayloadLen = (_frmPayloadLen << 8) | buf[pos];
          pos++;
          _frmExtLenRead++;
        }
        if (_frmExtLenRead < _frmExtLenBytes) break; // need more data

        _frmPayload = Uint8List(_frmPayloadLen);
        _frmPayloadRead = 0;
        _frmState = 2;
        continue;
      }

      if (_frmState == 2) {
        // Accumulate payload into pre-allocated buffer
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

      break; // unreachable
    }

    // Discard consumed bytes
    if (pos > 0) buf.removeRange(0, pos);
  }

  void _dispatchFrame(int opcode, Uint8List payload) {
    switch (opcode) {
      case 0x0: // continuation
      case 0x2: // binary
        if (!_inbound.isClosed) _inbound.add(payload);
        break;
      case 0x1: // text
        if (!_inbound.isClosed) _inbound.add(payload);
        break;
      case 0x9: // ping → send pong
        final sock = _socket;
        if (sock != null && payload.length <= 125) {
          sock.add(_encodePong(payload));
          // fire-and-forget flush for control frames
          sock.flush();
        }
        break;
      case 0x8: // close
        close();
        break;
    }
  }

  // ── frame encoder ─────────────────────────────────────────────────────────

  /// Masked binary frame (opcode 0x2). Client→server frames MUST be masked.
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

    frame[off++] = 0x82; // FIN=1, opcode=binary
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
    return Uint8List.fromList(
        [0x88, 0x80, mask[0], mask[1], mask[2], mask[3]]);
  }

  static Uint8List _encodePong(Uint8List pingPayload) {
    final mask = _randomMask();
    final len = pingPayload.length;
    final frame = Uint8List(2 + 4 + len);
    frame[0] = 0x8A; // FIN + pong
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

  static List<int> _randomMask() => [
        _rng.nextInt(256),
        _rng.nextInt(256),
        _rng.nextInt(256),
        _rng.nextInt(256),
      ];

  static String _generateWsKey() {
    final bytes = Uint8List(16);
    for (int i = 0; i < 16; i++) { bytes[i] = _rng.nextInt(256); }
    return base64.encode(bytes);
  }
}
