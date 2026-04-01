import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../../domain/entities/node.dart';

class UserdirException implements Exception {
  final String message;
  const UserdirException(this.message);
  @override
  String toString() => 'UserdirException: $message';
}

class UserdirServerError implements Exception {
  final int code;
  final String message;
  const UserdirServerError({required this.code, required this.message});
  @override
  String toString() => 'UserdirServerError($code): $message';
}

class UserdirErrorResponse {
  final int code;
  final String message;
  const UserdirErrorResponse({required this.code, required this.message});
}

class UserdirSearchResult {
  final Uint8List pubkey; // 32 bytes
  final String username; // includes leading "@"
  final String fullname;
  final Uint8List avatarSha256; // 32 bytes

  const UserdirSearchResult({
    required this.pubkey,
    required this.username,
    required this.fullname,
    required this.avatarSha256,
  });

  String get pubkeyHex =>
      pubkey.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

class UserdirProfile {
  final Uint8List pubkey; // 32 bytes
  final String username;
  final String fullname;
  final Uint8List avatarBytes;
  final Uint8List avatarSha256; // 32 bytes

  const UserdirProfile({
    required this.pubkey,
    required this.username,
    required this.fullname,
    required this.avatarBytes,
    required this.avatarSha256,
  });
}

class UserdirClient {
  static const int _msgRegisterOrUpdate = 0x01;
  static const int _msgSearch = 0x02;
  static const int _msgGetProfile = 0x03;
  static const int _msgOk = 0x81;
  static const int _msgError = 0x82;
  static const int _msgSearchResults = 0x83;
  static const int _msgProfile = 0x84;

  static const int _version = 1;
  static const int _sigAlgEd25519 = 1;

  final Duration connectTimeout;
  final Duration ioTimeout;

  const UserdirClient({
    this.connectTimeout = const Duration(milliseconds: 800),
    this.ioTimeout = const Duration(seconds: 2),
  });

  static bool isValidUsername(String username) {
    final v = username.trim();
    if (v.isEmpty) return false;
    return RegExp(r'^@[A-Za-z0-9_]{1,32}$').hasMatch(v);
  }

  Future<void> registerOrUpdate({
    required NodeConfig node,
    required String username,
    required String fullname,
    required Uint8List pubkey32,
    required Uint8List avatarBytes,
    required SimpleKeyPairData keyPair,
  }) async {
    if (pubkey32.length != 32) {
      throw ArgumentError('pubkey must be 32 bytes');
    }
    final user = username.trim();
    if (!isValidUsername(user)) {
      throw ArgumentError('Invalid username format');
    }

    final payload = BytesBuilder(copy: false)
      ..addByte(_version)
      ..add(_u16(_utf8Len(user)))
      ..add(utf8.encode(user))
      ..add(_u16(_utf8Len(fullname)))
      ..add(utf8.encode(fullname))
      ..add(pubkey32)
      ..add(_u32(avatarBytes.length))
      ..add(avatarBytes)
      ..addByte(_sigAlgEd25519)
      ..add(Uint8List(64)); // signature placeholder

    final frameBody = BytesBuilder(copy: false)
      ..addByte(_msgRegisterOrUpdate)
      ..add(payload.toBytes());

    final signed = await _signRegisterFrame(frameBody.toBytes(), keyPair);
    final response = await _sendAndRead(node, signed);

    if (response.msgType == _msgOk) return;
    if (response.msgType == _msgError) {
      throw UserdirServerError(
        code: response.error!.code,
        message: response.error!.message,
      );
    }
    throw UserdirException('Unexpected response type: 0x${response.msgType.toRadixString(16)}');
  }

  Future<List<UserdirSearchResult>> search({
    required NodeConfig node,
    required String query,
    int limit = 20,
  }) async {
    final q = query.trim();
    if (q.isEmpty) return const [];

    final payload = BytesBuilder(copy: false)
      ..addByte(_version)
      ..add(_u16(_utf8Len(q)))
      ..add(utf8.encode(q))
      ..add(_u16(limit.clamp(1, 65535)));

    final frameBody = BytesBuilder(copy: false)
      ..addByte(_msgSearch)
      ..add(payload.toBytes());

    final response = await _sendAndRead(node, frameBody.toBytes());

    if (response.msgType == _msgSearchResults) {
      final data = response.payload;
      final r = _Reader(data);
      final ver = r.u8();
      if (ver != _version) {
        throw UserdirException('Unsupported version: $ver');
      }
      final count = r.u16();
      final out = <UserdirSearchResult>[];
      for (var i = 0; i < count; i++) {
        final pubkey = r.bytes(32);
        final username = r.utf8(r.u16());
        final fullname = r.utf8(r.u16());
        final avatarSha = r.bytes(32);
        out.add(UserdirSearchResult(
          pubkey: pubkey,
          username: username,
          fullname: fullname,
          avatarSha256: avatarSha,
        ));
      }
      return out;
    }

    if (response.msgType == _msgError) {
      throw UserdirServerError(
        code: response.error!.code,
        message: response.error!.message,
      );
    }
    throw UserdirException('Unexpected response type: 0x${response.msgType.toRadixString(16)}');
  }

  Future<UserdirProfile> getProfile({
    required NodeConfig node,
    required Uint8List pubkey32,
  }) async {
    if (pubkey32.length != 32) {
      throw ArgumentError('pubkey must be 32 bytes');
    }

    final payload = BytesBuilder(copy: false)
      ..addByte(_version)
      ..add(pubkey32);

    final frameBody = BytesBuilder(copy: false)
      ..addByte(_msgGetProfile)
      ..add(payload.toBytes());

    final response = await _sendAndRead(node, frameBody.toBytes());

    if (response.msgType == _msgProfile) {
      final r = _Reader(response.payload);
      final ver = r.u8();
      if (ver != _version) {
        throw UserdirException('Unsupported version: $ver');
      }
      final pub = r.bytes(32);
      final username = r.utf8(r.u16());
      final fullname = r.utf8(r.u16());
      final avatarLen = r.u32();
      final avatar = r.bytes(avatarLen);
      final sha = r.bytes(32);
      return UserdirProfile(
        pubkey: pub,
        username: username,
        fullname: fullname,
        avatarBytes: avatar,
        avatarSha256: sha,
      );
    }

    if (response.msgType == _msgError) {
      throw UserdirServerError(
        code: response.error!.code,
        message: response.error!.message,
      );
    }
    throw UserdirException('Unexpected response type: 0x${response.msgType.toRadixString(16)}');
  }

  // ── Internal ────────────────────────────────────────────────────────────

  static Future<Uint8List> _signRegisterFrame(
    Uint8List frameBody,
    SimpleKeyPairData keyPair,
  ) async {
    if (frameBody.length < 1 + 64) {
      throw ArgumentError('Frame too short');
    }
    final algo = Ed25519();
    final toSign = frameBody.sublist(0, frameBody.length - 64);
    final sig = await algo.sign(toSign, keyPair: keyPair);
    if (sig.bytes.length != 64) {
      throw StateError('Ed25519 signature must be 64 bytes');
    }
    final out = Uint8List.fromList(frameBody);
    out.setRange(out.length - 64, out.length, sig.bytes);
    return out;
  }

  Future<_Response> _sendAndRead(NodeConfig node, Uint8List frameBody) async {
    final socket = await Socket.connect(
      node.host,
      node.usersPort,
      timeout: connectTimeout,
    );
    try {
      socket.add(_u32(frameBody.length));
      socket.add(frameBody);
      await socket.flush();

      final reader = _SocketReader(socket);
      final lenBytes = await reader.readExact(4).timeout(ioTimeout);
      final len = ByteData.sublistView(lenBytes).getUint32(0, Endian.big);
      final body = await reader.readExact(len).timeout(ioTimeout);

      final msgType = body[0];
      final payload = body.sublist(1);

      if (msgType == _msgError) {
        final r = _Reader(payload);
        final code = r.u16();
        final msgLen = r.u16();
        final msg = r.utf8(msgLen);
        return _Response(
          msgType: msgType,
          payload: payload,
          error: UserdirErrorResponse(code: code, message: msg),
        );
      }

      return _Response(msgType: msgType, payload: payload);
    } finally {
      socket.destroy();
    }
  }

  static int _utf8Len(String s) => utf8.encode(s).length;

  static Uint8List _u16(int v) {
    final b = ByteData(2)..setUint16(0, v, Endian.big);
    return b.buffer.asUint8List();
  }

  static Uint8List _u32(int v) {
    final b = ByteData(4)..setUint32(0, v, Endian.big);
    return b.buffer.asUint8List();
  }
}

class _Response {
  final int msgType;
  final Uint8List payload;
  final UserdirErrorResponse? error;
  const _Response({required this.msgType, required this.payload, this.error});
}

class _Reader {
  final Uint8List data;
  int offset = 0;
  _Reader(this.data);

  int u8() => data[offset++];

  int u16() {
    final v = ByteData.sublistView(data, offset, offset + 2)
        .getUint16(0, Endian.big);
    offset += 2;
    return v;
  }

  int u32() {
    final v = ByteData.sublistView(data, offset, offset + 4)
        .getUint32(0, Endian.big);
    offset += 4;
    return v;
  }

  Uint8List bytes(int n) {
    final out = Uint8List.sublistView(data, offset, offset + n);
    offset += n;
    return Uint8List.fromList(out);
  }

  String utf8(int n) => utf8.decode(bytes(n), allowMalformed: true);
}

class _SocketReader {
  final StreamIterator<Uint8List> _it;
  Uint8List _stash = Uint8List(0);
  int _stashOffset = 0;

  _SocketReader(Socket socket) : _it = StreamIterator<Uint8List>(socket);

  Future<Uint8List> readExact(int n) async {
    if (n <= 0) return Uint8List(0);
    final out = BytesBuilder(copy: false);
    var remaining = n;
    while (remaining > 0) {
      if (_stashOffset < _stash.length) {
        final take = (_stash.length - _stashOffset).clamp(0, remaining) as int;
        out.add(Uint8List.sublistView(_stash, _stashOffset, _stashOffset + take));
        _stashOffset += take;
        remaining -= take;
        continue;
      }

      final hasNext = await _it.moveNext();
      if (!hasNext) throw const UserdirException('Unexpected EOF');
      _stash = _it.current;
      _stashOffset = 0;
    }
    return out.toBytes();
  }
}
