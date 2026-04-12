import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:sgtp_flutter/core/app_logger.dart';
import 'package:sgtp_flutter/core/network/i_protocol_transport.dart';
import 'package:sgtp_flutter/core/sgtp_server_options.dart';

const _tag = 'TCP';

class TcpSgtpTransport implements IProtocolTransport {
  final String host;
  final int port;
  final bool useTls;
  final String? fakeSni;

  final StreamController<Uint8List> _inbound =
      StreamController<Uint8List>.broadcast();
  void Function(Uint8List)? _packetCallback;
  Socket? _socket;
  StreamSubscription? _sub;

  TcpSgtpTransport({
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
    AppLogger.d(
      'Connecting to $host:$port (tls=$useTls, sni=${tlsSni.isEmpty ? host : tlsSni})',
      tag: _tag,
    );
    Socket s;
    try {
      if (useTls) {
        final tlsServerName = (fakeSni ?? '').trim();
        AppLogger.d('Starting TLS handshake with $host:$port', tag: _tag);
        if (tlsServerName.isNotEmpty &&
            tlsServerName.toLowerCase() != host.toLowerCase()) {
          final raw = await Socket.connect(host, port);
          s = await SecureSocket.secure(
            raw,
            host: tlsServerName,
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
        } else {
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
        }
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

    try {
      s.setOption(SocketOption.tcpNoDelay, true);
    } catch (_) {}

    try {
      s.setRawOption(RawSocketOption(
        RawSocketOption.levelSocket,
        9, // SO_KEEPALIVE
        Uint8List.fromList([1, 0, 0, 0]),
      ));
    } catch (_) {}

    _socket = s;

    const int discoveryHeaderLen = SgtpServerOptions.wireBytesLength;
    final headerBuf = BytesBuilder();
    final headerDone = Completer<void>();

    _sub = s.listen(
      (chunk) {
        if (!headerDone.isCompleted) {
          headerBuf.add(chunk);
          if (headerBuf.length >= discoveryHeaderLen) {
            final all = headerBuf.toBytes();
            if (all.length > discoveryHeaderLen) {
              final bytes =
                  Uint8List.fromList(all.sublist(discoveryHeaderLen));
              _inbound.add(bytes);
              _packetCallback?.call(bytes);
            }
            headerDone.complete();
          }
        } else {
          final bytes = Uint8List.fromList(chunk);
          _inbound.add(bytes);
          _packetCallback?.call(bytes);
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

    try {
      await headerDone.future.timeout(
        const Duration(seconds: 15),
        onTimeout: () => throw TimeoutException(
            'Banner timeout on $host:$port (tls=$useTls) after 15s'),
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
    try {
      s.add(bytes);
      await s.flush();
    } on StateError {
      _socket = null;
      rethrow;
    } on SocketException {
      _socket = null;
      rethrow;
    }
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
