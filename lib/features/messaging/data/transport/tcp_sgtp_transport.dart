import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:sgtp_flutter/core/app_logger.dart';
import 'package:sgtp_flutter/core/sgtp_server_options.dart';
import 'package:sgtp_flutter/features/messaging/data/transport/sgtp_transport.dart';

const _tag = 'TCP';

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
    AppLogger.d('Connecting to $host:$port (tls=$useTls)', tag: _tag);
    Socket s;
    try {
      if (useTls) {
        AppLogger.d('Starting TLS handshake with $host:$port', tag: _tag);
        s = await SecureSocket.connect(
          host,
          port,
          onBadCertificate: (cert) {
            AppLogger.e(
              'TLS cert rejected by Dart: subject="${cert.subject}" '
              'issuer="${cert.issuer}" '
              'valid=${cert.startValidity}–${cert.endValidity}',
              tag: _tag,
            );
            return false;
          },
        );
        final secure = s as SecureSocket;
        AppLogger.d(
          'TLS handshake OK: '
          'cert-subject=${secure.peerCertificate?.subject ?? "none"}',
          tag: _tag,
        );
      } else {
        s = await Socket.connect(host, port);
      }
    } catch (e) {
      AppLogger.e(
        'Connect failed to $host:$port (tls=$useTls) [${e.runtimeType}]: $e',
        tag: _tag,
      );
      rethrow;
    }
    AppLogger.d('Socket established $host:$port (tls=$useTls)', tag: _tag);

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

    // ── Read the 25-byte discovery header ─────────────────────────────────
    // The server (serveTCP in multi.go) sends the 25-byte discovery payload
    // immediately after accepting every TCP relay connection.  We must
    // consume exactly those bytes before feeding data to the relay loop;
    // otherwise the frame parser sees 25 bytes of garbage at the front of
    // the stream and corrupts subsequent SGTP frames.
    //
    // Discovery clients (SgtpServerDiscovery / "Fetch server options") also
    // connect to the TCP relay port, read the same 25 bytes, and close —
    // so both use-cases are served by the same server-side change.
    const int discoveryHeaderLen = SgtpServerOptions.wireBytesLength; // 25
    final headerBuf = BytesBuilder();
    final headerDone = Completer<void>();

    _sub = s.listen(
      (chunk) {
        if (!headerDone.isCompleted) {
          // Still accumulating the discovery header.
          headerBuf.add(chunk);

          if (headerBuf.length >= discoveryHeaderLen) {
            // Full 25-byte header received (chunk may also contain relay bytes).
            final all = headerBuf.toBytes();

            // Bytes past the header belong to the relay stream.
            // Inject them BEFORE completing the future so they are always
            // the first bytes the relay loop processes. (Dart is single-
            // threaded; no other stream event fires until this callback
            // returns, guaranteeing correct ordering.)
            if (all.length > discoveryHeaderLen) {
              _inbound.add(
                  Uint8List.fromList(all.sublist(discoveryHeaderLen)));
            }

            headerDone.complete();
          }
          // Haven't accumulated 25 bytes yet — keep buffering.
        } else {
          // Header consumed — forward relay data directly.
          _inbound.add(Uint8List.fromList(chunk));
        }
      },
      onError: (e, st) {
        AppLogger.e('Socket error on $host:$port (tls=$useTls): $e', tag: _tag);
        if (!headerDone.isCompleted) headerDone.completeError(e, st);
        _inbound.addError(e, st);
      },
      onDone: () {
        if (!headerDone.isCompleted) {
          final err = StateError(
              'Connection closed before 25-byte banner on $host:$port');
          AppLogger.e('$err', tag: _tag);
          headerDone.completeError(err);
        }
        if (!_inbound.isClosed) _inbound.close();
      },
      cancelOnError: false,
    );

    // Wait up to 3 s for the server to send its discovery header.
    try {
      await headerDone.future.timeout(
        const Duration(seconds: 3),
        onTimeout: () => throw TimeoutException(
            'Banner timeout on $host:$port (tls=$useTls) after 3s'),
      );
    } catch (e) {
      AppLogger.e('Banner wait failed on $host:$port (tls=$useTls): $e',
          tag: _tag);
      rethrow;
    }
    AppLogger.d('Banner received on $host:$port (tls=$useTls)', tag: _tag);
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

