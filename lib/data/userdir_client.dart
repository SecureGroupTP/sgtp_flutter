import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../core/app_logger.dart';
import '../core/sgtp_server_options.dart';

const _tag = 'UDIR';

String _msgName(int t) => switch (t) {
      0x01 => 'REGISTER',
      0x02 => 'SEARCH',
      0x03 => 'GET_PROFILE',
      0x04 => 'GET_META',
      0x05 => 'SUBSCRIBE',
      0x06 => 'UNSUBSCRIBE',
      0x81 => 'OK',
      0x82 => 'ERROR',
      0x83 => 'SEARCH_RESULTS',
      0x84 => 'PROFILE',
      0x85 => 'META',
      0x86 => 'NOTIFY',
      _ => '0x${t.toRadixString(16).padLeft(2, '0')}',
    };

/// Lightweight profile data returned by GET_META / NOTIFY.
class UserDirMeta {
  final Uint8List pubkey;
  final String username;
  final String fullname;
  final Uint8List avatarSha256; // 32 bytes
  final int updatedAt; // unix seconds

  const UserDirMeta({
    required this.pubkey,
    required this.username,
    required this.fullname,
    required this.avatarSha256,
    required this.updatedAt,
  });

  String get pubkeyHex =>
      pubkey.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  String get avatarSha256Hex =>
      avatarSha256.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

/// Full profile including avatar bytes, returned by GET_PROFILE.
class UserDirProfile extends UserDirMeta {
  final Uint8List avatarBytes;

  const UserDirProfile({
    required super.pubkey,
    required super.username,
    required super.fullname,
    required super.avatarSha256,
    required super.updatedAt,
    required this.avatarBytes,
  });
}

/// Binary protocol client for the SGTP user directory service.
///
/// The userdir is multiplexed on the same TCP port as the chat relay.
/// A client signals userdir intent by sending exactly 32 zero bytes
/// before the first protocol frame.
///
/// All frames are: u32 frame_len (big-endian) | u8 msg_type | payload.
/// Requests are sequential (no concurrent in-flight messages).
/// NOTIFY (0x86) is unsolicited and handled via [notifyStream].
class UserDirClient {
  final String host;
  final int port;

  Socket? _socket;
  final _buf = <int>[];
  final _pending = <Completer<Uint8List?>>[];
  StreamController<UserDirMeta>? _notifyCtrl;
  var _closed = false;
  int _bannerBytesRemaining = SgtpServerOptions.wireBytesLength;

  UserDirClient({required this.host, required this.port});

  Stream<UserDirMeta> get notifyStream {
    _notifyCtrl ??= StreamController<UserDirMeta>.broadcast();
    return _notifyCtrl!.stream;
  }

  /// Connect to the relay port and send the 32-byte zero magic prefix.
  Future<void> connect() async {
    AppLogger.i('Connecting to $host:$port', tag: _tag);
    _socket = await Socket.connect(host, port,
        timeout: const Duration(seconds: 10));
    _socket!.add(Uint8List(32)); // userdir routing magic
    AppLogger.d('→ OUTBOUND  MAGIC          32B (zero routing prefix)', tag: _tag);
    _socket!.listen(
      _onData,
      onError: (e) {
        AppLogger.e('Disconnected from $host:$port — socket error: $e',
            tag: _tag);
        _fail();
      },
      onDone: () {
        if (!_closed) {
          AppLogger.w(
              'Disconnected from $host:$port — server closed the connection',
              tag: _tag);
        }
        _fail();
      },
      cancelOnError: true,
    );
    AppLogger.i('Connected to $host:$port', tag: _tag);
  }

  void _onData(List<int> data) {
    final hex = data.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
    AppLogger.d('← RAW  ${data.length}B: $hex', tag: _tag);

    var start = 0;
    if (_bannerBytesRemaining > 0) {
      final skip = data.length.clamp(0, _bannerBytesRemaining);
      _bannerBytesRemaining -= skip;
      start = skip;
      AppLogger.d(
        'BANNER skip ${skip}B  remaining=${_bannerBytesRemaining}B',
        tag: _tag,
      );
      if (start >= data.length) return;
    }

    _buf.addAll(data.sublist(start));
    _processBuffer();
  }

  void _processBuffer() {
    while (_buf.length >= 4) {
      final frameLen =
          (_buf[0] << 24) | (_buf[1] << 16) | (_buf[2] << 8) | _buf[3];
      AppLogger.d(
          'PARSE buf=${_buf.length}B  frameLen=$frameLen  '
          'need=${4 + frameLen}B',
          tag: _tag);
      if (_buf.length < 4 + frameLen) break;
      final frame = Uint8List.fromList(_buf.sublist(4, 4 + frameLen));
      _buf.removeRange(0, 4 + frameLen);
      _handleFrame(frame);
    }
  }

  void _handleFrame(Uint8List frame) {
    if (frame.isEmpty) return;
    final msgType = frame[0];
    final payload = frame.sublist(1);

    if (msgType == 0x86) {
      // NOTIFY — unsolicited push from server
      final meta = _parseMeta(payload);
      AppLogger.d(
        '← INBOUND   ${_msgName(msgType).padRight(14)} '
        '${payload.length}B  pubkey=${meta?.pubkeyHex.substring(0, 8) ?? '?'}',
        tag: _tag,
      );
      if (meta != null) _notifyCtrl?.add(meta);
      return;
    }

    AppLogger.d(
      '← INBOUND   ${_msgName(msgType).padRight(14)} ${payload.length}B',
      tag: _tag,
    );

    if (msgType == 0x82) {
      // ERROR frame — log the server message
      try {
        if (payload.length >= 4) {
          final code = (payload[0] << 8) | payload[1];
          final msgLen = (payload[2] << 8) | payload[3];
          final msg = msgLen > 0
              ? utf8.decode(payload.sublist(4, 4 + msgLen))
              : '';
          AppLogger.w('Server error code=0x${code.toRadixString(16)} "$msg"',
              tag: _tag);
        }
      } catch (_) {}
    }

    if (_pending.isNotEmpty) {
      final c = _pending.removeAt(0);
      c.complete(frame); // includes the msgType byte at index 0
    }
  }

  void _fail() {
    _closed = true;
    for (final c in _pending) {
      c.complete(null);
    }
    _pending.clear();
    _notifyCtrl?.close();
  }

  Future<Uint8List?> _send(int msgType, Uint8List payload) async {
    if (_closed || _socket == null) return null;

    final body = Uint8List(1 + payload.length);
    body[0] = msgType;
    body.setRange(1, body.length, payload);

    final len = body.length;
    final frame = Uint8List(4 + len);
    frame[0] = (len >> 24) & 0xff;
    frame[1] = (len >> 16) & 0xff;
    frame[2] = (len >> 8) & 0xff;
    frame[3] = len & 0xff;
    frame.setRange(4, frame.length, body);

    AppLogger.d(
      '→ OUTBOUND  ${_msgName(msgType).padRight(14)} ${payload.length}B',
      tag: _tag,
    );

    final c = Completer<Uint8List?>();
    _pending.add(c);
    _socket!.add(frame);

    return c.future.timeout(const Duration(seconds: 15), onTimeout: () {
      AppLogger.w('${_msgName(msgType)} timed out', tag: _tag);
      _pending.remove(c);
      return null;
    });
  }

  /// Registers (or updates) the caller's own profile on the server.
  ///
  /// [username] must match `^@[A-Za-z0-9_]{1,32}$`.
  /// The payload is signed with [identityKeyPair] using Ed25519.
  Future<bool> register({
    required String? username,
    required String fullname,
    required Uint8List pubkey,
    required Uint8List avatarBytes,
    required SimpleKeyPairData identityKeyPair,
  }) async {
    final usernameBytes = utf8.encode(username ?? '');
    final fullnameBytes = utf8.encode(fullname);
    final avatarLen = avatarBytes.length;

    // Build payload without signature (65 bytes placeholder at end)
    final payloadSize = 1 + // version
        2 + usernameBytes.length +
        2 + fullnameBytes.length +
        32 + // pubkey
        4 + avatarLen +
        1 + // sig_alg
        64; // signature placeholder
    final payload = Uint8List(payloadSize);
    var o = 0;
    payload[o++] = 1; // version
    payload[o++] = (usernameBytes.length >> 8) & 0xff;
    payload[o++] = usernameBytes.length & 0xff;
    payload.setRange(o, o + usernameBytes.length, usernameBytes);
    o += usernameBytes.length;
    payload[o++] = (fullnameBytes.length >> 8) & 0xff;
    payload[o++] = fullnameBytes.length & 0xff;
    payload.setRange(o, o + fullnameBytes.length, fullnameBytes);
    o += fullnameBytes.length;
    payload.setRange(o, o + 32, pubkey);
    o += 32;
    payload[o++] = (avatarLen >> 24) & 0xff;
    payload[o++] = (avatarLen >> 16) & 0xff;
    payload[o++] = (avatarLen >> 8) & 0xff;
    payload[o++] = avatarLen & 0xff;
    payload.setRange(o, o + avatarLen, avatarBytes);
    o += avatarLen;
    payload[o++] = 1; // sig_alg = Ed25519
    // last 64 bytes are the signature slot (currently zero)

    // Sign: msg_type(0x01) || payload_without_last_64
    final toSign = Uint8List(1 + payloadSize - 64);
    toSign[0] = 0x01; // msg_type
    toSign.setRange(1, toSign.length, payload.sublist(0, payloadSize - 64));
    final sig =
        await Ed25519().sign(toSign, keyPair: identityKeyPair);
    payload.setRange(payloadSize - 64, payloadSize, sig.bytes);

    AppLogger.d(
      '→ OUTBOUND  REGISTER       '
      'username=$username  fullname=$fullname  avatar=${avatarLen}B',
      tag: _tag,
    );

    final resp = await _send(0x01, payload);
    final ok = resp != null && resp.isNotEmpty && resp[0] == 0x81;
    if (ok) {
      AppLogger.i('REGISTER OK  username=$username', tag: _tag);
    } else {
      AppLogger.w(
          'REGISTER failed  ${resp == null ? 'null' : _msgName(resp[0])}${_errorDetail(resp)}',
          tag: _tag);
    }
    return ok;
  }

  /// Fetches lightweight metadata (no avatar bytes) for [pubkey].
  /// Returns null on error or if the profile is not found.
  Future<UserDirMeta?> getMeta(Uint8List pubkey) async {
    final pk8 = pubkey.map((b) => b.toRadixString(16).padLeft(2, '0')).join().substring(0, 8);
    AppLogger.d('GET_META pubkey=$pk8…', tag: _tag);
    final payload = Uint8List(33);
    payload[0] = 1; // version
    payload.setRange(1, 33, pubkey);
    final resp = await _send(0x04, payload);
    if (resp == null || resp.isEmpty || resp[0] != 0x85) {
      AppLogger.w(
          'GET_META failed for $pk8…  ${resp == null ? 'null' : _msgName(resp[0])}${_errorDetail(resp)}',
          tag: _tag);
      return null;
    }
    return _parseMeta(resp.sublist(1));
  }

  /// Fetches the full profile including avatar bytes for [pubkey].
  Future<UserDirProfile?> getProfile(Uint8List pubkey) async {
    final pk8 = pubkey.map((b) => b.toRadixString(16).padLeft(2, '0')).join().substring(0, 8);
    AppLogger.d('GET_PROFILE pubkey=$pk8…', tag: _tag);
    final payload = Uint8List(33);
    payload[0] = 1; // version
    payload.setRange(1, 33, pubkey);
    final resp = await _send(0x03, payload);
    if (resp == null || resp.isEmpty || resp[0] != 0x84) {
      AppLogger.w(
          'GET_PROFILE failed for $pk8…  ${resp == null ? 'null' : _msgName(resp[0])}${_errorDetail(resp)}',
          tag: _tag);
      return null;
    }
    final profile = _parseProfile(resp.sublist(1));
    if (profile != null) {
      AppLogger.d(
        'PROFILE received  pubkey=$pk8…  avatar=${profile.avatarBytes.length}B',
        tag: _tag,
      );
    }
    return profile;
  }

  /// Subscribes to change notifications for the given list of public keys.
  /// The server will send NOTIFY frames when any subscribed profile is updated.
  Future<bool> subscribe(List<Uint8List> pubkeys) async {
    if (pubkeys.isEmpty) return true;
    AppLogger.i('SUBSCRIBE to ${pubkeys.length} contact(s)', tag: _tag);
    final count = pubkeys.length;
    final payload = Uint8List(3 + count * 32);
    payload[0] = 1; // version
    payload[1] = (count >> 8) & 0xff;
    payload[2] = count & 0xff;
    var offset = 3;
    for (final pk in pubkeys) {
      payload.setRange(offset, offset + 32, pk);
      offset += 32;
    }
    final resp = await _send(0x05, payload);
    final ok = resp != null && resp.isNotEmpty && resp[0] == 0x81;
    if (ok) {
      AppLogger.i('SUBSCRIBE OK — listening for NOTIFY', tag: _tag);
    } else {
      final detail = _errorDetail(resp);
      AppLogger.w('SUBSCRIBE failed  ${_msgName(resp?[0] ?? 0)}$detail',
          tag: _tag);
    }
    return ok;
  }

  UserDirMeta? _parseMeta(Uint8List data) {
    try {
      var o = 0;
      if (data[o++] != 1) return null; // version check
      final pubkey = Uint8List.fromList(data.sublist(o, o + 32));
      o += 32;
      final usernameLen = (data[o] << 8) | data[o + 1];
      o += 2;
      final username = utf8.decode(data.sublist(o, o + usernameLen));
      o += usernameLen;
      final fullnameLen = (data[o] << 8) | data[o + 1];
      o += 2;
      final fullname = utf8.decode(data.sublist(o, o + fullnameLen));
      o += fullnameLen;
      final sha256 = Uint8List.fromList(data.sublist(o, o + 32));
      o += 32;
      final updatedAt = _readU64(data, o);
      return UserDirMeta(
        pubkey: pubkey,
        username: username,
        fullname: fullname,
        avatarSha256: sha256,
        updatedAt: updatedAt,
      );
    } catch (_) {
      return null;
    }
  }

  UserDirProfile? _parseProfile(Uint8List data) {
    try {
      var o = 0;
      if (data[o++] != 1) return null;
      final pubkey = Uint8List.fromList(data.sublist(o, o + 32));
      o += 32;
      final usernameLen = (data[o] << 8) | data[o + 1];
      o += 2;
      final username = utf8.decode(data.sublist(o, o + usernameLen));
      o += usernameLen;
      final fullnameLen = (data[o] << 8) | data[o + 1];
      o += 2;
      final fullname = utf8.decode(data.sublist(o, o + fullnameLen));
      o += fullnameLen;
      final avatarLen = (data[o] << 24) |
          (data[o + 1] << 16) |
          (data[o + 2] << 8) |
          data[o + 3];
      o += 4;
      final avatarBytes = Uint8List.fromList(data.sublist(o, o + avatarLen));
      o += avatarLen;
      final sha256 = Uint8List.fromList(data.sublist(o, o + 32));
      o += 32;
      final updatedAt = _readU64(data, o);
      return UserDirProfile(
        pubkey: pubkey,
        username: username,
        fullname: fullname,
        avatarBytes: avatarBytes,
        avatarSha256: sha256,
        updatedAt: updatedAt,
      );
    } catch (_) {
      return null;
    }
  }

  /// Returns " code=0xNNNN msg" if [resp] is an ERROR frame, otherwise "".
  String _errorDetail(Uint8List? resp) {
    if (resp == null || resp.isEmpty || resp[0] != 0x82) return '';
    try {
      final payload = resp.sublist(1);
      if (payload.length < 4) return '';
      final code = (payload[0] << 8) | payload[1];
      final msgLen = (payload[2] << 8) | payload[3];
      final msg =
          msgLen > 0 ? utf8.decode(payload.sublist(4, 4 + msgLen)) : '';
      return '  code=0x${code.toRadixString(16).padLeft(4, '0')} "$msg"';
    } catch (_) {
      return '';
    }
  }

  int _readU64(Uint8List data, int offset) {
    var result = 0;
    for (var i = 0; i < 8; i++) {
      result = (result << 8) | data[offset + i];
    }
    return result;
  }

  void close() {
    if (_closed) return;
    AppLogger.i('Disconnected from $host:$port — closed by client', tag: _tag);
    _closed = true;
    _socket?.destroy();
    _notifyCtrl?.close();
  }
}
