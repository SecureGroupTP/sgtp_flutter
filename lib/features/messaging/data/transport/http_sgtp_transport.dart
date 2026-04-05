import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'package:sgtp_flutter/features/messaging/data/transport/http_client_factory.dart';
import 'package:sgtp_flutter/features/messaging/data/transport/sgtp_transport.dart';

class HttpSgtpTransport implements SgtpTransport {
  final String host;
  final int port;
  final bool useTls;

  final http.Client _client = createSgtpHttpClient();
  final StreamController<Uint8List> _inbound =
      StreamController<Uint8List>.broadcast();

  String? _sidHex;
  bool _closing = false;
  Future<void>? _recvLoop;

  HttpSgtpTransport({
    required this.host,
    required this.port,
    required this.useTls,
  });

  Uri _uri(String path, [Map<String, String>? query]) {
    return Uri(
      scheme: useTls ? 'https' : 'http',
      host: host,
      port: port,
      path: path,
      queryParameters: query,
    );
  }

  @override
  Stream<Uint8List> get inbound => _inbound.stream;

  @override
  bool get isConnected => _sidHex != null;

  @override
  Future<void> connect() async {
    if (_sidHex != null) return;
    final sid = await _createSession();
    _sidHex = sid;
    _recvLoop = _startRecvLoop();
  }

  Future<String> _createSession() async {
    final req = http.Request('POST', _uri('/sgtp/session'))
      ..headers['Accept'] = 'application/octet-stream'
      ..headers['Content-Type'] = 'application/octet-stream';
    final res = await _client.send(req);
    final body = await _readAll(res.stream);
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw StateError(
          'HTTP session create failed: ${res.statusCode} ${res.reasonPhrase ?? ''}');
    }

    // Spec: 16 raw bytes. Also accept JSON {"sid":"..."} for flexibility.
    final ct = (res.headers['content-type'] ?? '').toLowerCase();
    if (ct.contains('json')) {
      final decoded = json.decode(utf8.decode(body)) as Map<String, dynamic>;
      final sid = (decoded['sid'] as String? ?? '').trim();
      if (sid.isEmpty) throw StateError('Missing sid');
      return sid;
    }
    if (body.length != 16) {
      throw StateError('Invalid sid length: ${body.length}');
    }
    return body.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  Future<Uint8List> _readAll(Stream<List<int>> stream) async {
    final buf = BytesBuilder(copy: false);
    await for (final chunk in stream) {
      if (chunk.isEmpty) continue;
      buf.add(chunk);
    }
    return buf.takeBytes();
  }

  Future<void> _startRecvLoop() async {
    while (!_closing) {
      final sid = _sidHex;
      if (sid == null) return;
      try {
        final req = http.Request('GET', _uri('/sgtp/recv', {'sid': sid}))
          ..headers['Accept'] = 'application/octet-stream';
        final res = await _client.send(req);
        if (res.statusCode != 200) {
          await res.stream.drain<void>();
          throw StateError(
              'HTTP recv failed: ${res.statusCode} ${res.reasonPhrase ?? ''}');
        }
        await for (final chunk in res.stream) {
          if (_closing) break;
          if (chunk.isEmpty) continue;
          _inbound.add(Uint8List.fromList(chunk));
        }
      } catch (e, st) {
        if (_closing) return;
        _inbound.addError(e, st);
        await Future<void>.delayed(const Duration(seconds: 1));
      }
    }
  }

  @override
  Future<void> send(Uint8List bytes) async {
    final sid = _sidHex;
    if (sid == null) throw StateError('Not connected');
    final req = http.Request('POST', _uri('/sgtp/send', {'sid': sid}))
      ..headers['Content-Type'] = 'application/octet-stream'
      ..bodyBytes = bytes;
    final res = await _client.send(req);
    await res.stream.drain<void>();
    if (res.statusCode != 204 && res.statusCode != 200) {
      throw StateError(
          'HTTP send failed: ${res.statusCode} ${res.reasonPhrase ?? ''}');
    }
  }

  @override
  Future<void> close() async {
    _closing = true;
    final sid = _sidHex;
    _sidHex = null;
    if (sid != null) {
      try {
        final req = http.Request('DELETE', _uri('/sgtp/session', {'sid': sid}));
        final res = await _client.send(req);
        await res.stream.drain<void>();
      } catch (_) {}
    }
    try {
      await _recvLoop;
    } catch (_) {}
    _client.close();
    if (!_inbound.isClosed) {
      await _inbound.close();
    }
  }
}
