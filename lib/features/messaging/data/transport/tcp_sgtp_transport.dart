import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:sgtp_flutter/core/app_log.dart';
import 'package:sgtp_flutter/core/network/i_protocol_transport.dart';
import 'package:sgtp_flutter/core/sgtp_server_options.dart';

final _log = AppLog('TcpSgtpTransport');

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
    _log.debug('Connecting to {host}:{port} (tls={useTls}, sni={sni})', parameters: {'host': host, 'port': port, 'useTls': useTls, 'sni': tlsSni.isEmpty ? host : tlsSni});
    Socket s;
    try {
      if (useTls) {
        final tlsServerName = (fakeSni ?? '').trim();
        _log.debug('Starting TLS handshake with {host}:{port}', parameters: {'host': host, 'port': port});
        if (tlsServerName.isNotEmpty &&
            tlsServerName.toLowerCase() != host.toLowerCase()) {
          final raw = await Socket.connect(host, port);
          s = await SecureSocket.secure(
            raw,
            host: tlsServerName,
            onBadCertificate: (cert) {
              _log.error('TLS cert rejected by Dart: subject="{subject}" issuer="{issuer}" valid={validFrom}–{validTo}', parameters: {'subject': cert.subject, 'issuer': cert.issuer, 'validFrom': cert.startValidity, 'validTo': cert.endValidity});
              return false;
            },
          );
        } else {
          s = await SecureSocket.connect(
            host,
            port,
            onBadCertificate: (cert) {
              _log.error('TLS cert rejected by Dart: subject="{subject}" issuer="{issuer}" valid={validFrom}–{validTo}', parameters: {'subject': cert.subject, 'issuer': cert.issuer, 'validFrom': cert.startValidity, 'validTo': cert.endValidity});
              return false;
            },
          );
        }
        final secure = s as SecureSocket;
        _log.debug('TLS handshake OK: cert-subject={subject}', parameters: {'subject': secure.peerCertificate?.subject ?? 'none'});
      } else {
        s = await Socket.connect(host, port);
      }
    } catch (e) {
      _log.error('Connect failed to {host}:{port} (tls={useTls}) [{type}]: {error}', parameters: {'host': host, 'port': port, 'useTls': useTls, 'type': e.runtimeType, 'error': e});
      rethrow;
    }
    _log.debug('Socket established {host}:{port} (tls={useTls})', parameters: {'host': host, 'port': port, 'useTls': useTls});

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
        _log.error('Socket error on {host}:{port} (tls={useTls}): {error}', parameters: {'host': host, 'port': port, 'useTls': useTls, 'error': e});
        if (!headerDone.isCompleted) headerDone.completeError(e, st);
        _inbound.addError(e, st);
      },
      onDone: () {
        if (!headerDone.isCompleted) {
          final err = StateError(
              'Connection closed before 25-byte banner on $host:$port');
          _log.error('{error}', parameters: {'error': err});
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
      _log.error('Banner wait failed on {host}:{port} (tls={useTls}): {error}', parameters: {'host': host, 'port': port, 'useTls': useTls, 'error': e});
      rethrow;
    }
    _log.debug('Banner received on {host}:{port} (tls={useTls})', parameters: {'host': host, 'port': port, 'useTls': useTls});
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
