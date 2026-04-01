import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'sgtp_transport.dart';

class HttpSgtpTransport implements SgtpTransport {
  final String host;
  final int port;
  final bool useTls;

  final HttpClient _client = HttpClient();
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
    final req = await _client.postUrl(_uri('/sgtp/session'));
    req.headers.contentType = ContentType.binary;
    final res = await req.close();
    final body = await _readAll(res);
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw HttpException(
          'HTTP session create failed: ${res.statusCode} ${res.reasonPhrase}');
    }

    // Spec: 16 raw bytes. Also accept JSON {"sid":"..."} for flexibility.
    final ct = res.headers.contentType?.mimeType ?? '';
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

  Future<Uint8List> _readAll(HttpClientResponse res) async {
    final buf = BytesBuilder(copy: false);
    await for (final chunk in res) {
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
        final req = await _client.getUrl(_uri('/sgtp/recv', {'sid': sid}));
        final res = await req.close();
        if (res.statusCode != 200) {
          await res.drain();
          throw HttpException(
              'HTTP recv failed: ${res.statusCode} ${res.reasonPhrase}');
        }
        await for (final chunk in res) {
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
    final req = await _client.postUrl(_uri('/sgtp/send', {'sid': sid}));
    req.headers.contentType = ContentType.binary;
    req.add(bytes);
    final res = await req.close();
    await res.drain();
    if (res.statusCode != 204 && res.statusCode != 200) {
      throw HttpException(
          'HTTP send failed: ${res.statusCode} ${res.reasonPhrase}');
    }
  }

  @override
  Future<void> close() async {
    _closing = true;
    final sid = _sidHex;
    _sidHex = null;
    if (sid != null) {
      try {
        final req = await _client.deleteUrl(_uri('/sgtp/session', {'sid': sid}));
        final res = await req.close();
        await res.drain();
      } catch (_) {}
    }
    try {
      await _recvLoop;
    } catch (_) {}
    _client.close(force: true);
    if (!_inbound.isClosed) {
      await _inbound.close();
    }
  }
}
