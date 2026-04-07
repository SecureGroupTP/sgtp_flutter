import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'package:sgtp_flutter/core/app_logger.dart';
import 'package:sgtp_flutter/core/sgtp_server_options.dart';
import 'package:sgtp_flutter/core/sgtp_transport.dart';
import 'package:sgtp_flutter/features/contacts/domain/repositories/i_user_dir_client.dart';
import 'package:sgtp_flutter/features/setup/domain/entities/node.dart';
import 'package:sgtp_flutter/features/messaging/data/transport/http_sgtp_transport.dart';
import 'package:sgtp_flutter/features/messaging/data/transport/sgtp_transport.dart';
import 'package:sgtp_flutter/features/messaging/data/transport/tcp_sgtp_transport.dart';
import 'package:sgtp_flutter/features/messaging/data/transport/websocket_sgtp_transport.dart';

export 'package:sgtp_flutter/features/contacts/domain/repositories/i_user_dir_client.dart';
export 'package:sgtp_flutter/features/messaging/data/transport/sgtp_transport.dart'
    show SgtpTransport;

const _tag = 'UDIR';

String _msgName(int t) => switch (t) {
      0x01 => 'REGISTER',
      0x02 => 'SEARCH',
      0x03 => 'GET_PROFILE',
      0x04 => 'GET_META',
      0x05 => 'SUBSCRIBE',
      0x06 => 'UNSUBSCRIBE',
      0x07 => 'FRIEND_REQUEST',
      0x08 => 'FRIEND_RESPONSE',
      0x09 => 'FRIEND_SYNC',
      0x0a => 'FRIEND_DELETE',
      0x81 => 'OK',
      0x82 => 'ERROR',
      0x83 => 'SEARCH_RESULTS',
      0x84 => 'PROFILE',
      0x85 => 'META',
      0x86 => 'NOTIFY',
      0x87 => 'FRIEND_STATE',
      0x88 => 'FRIEND_NOTIFY',
      _ => '0x${t.toRadixString(16).padLeft(2, '0')}',
    };

/// Binary protocol client for the SGTP user directory service.
///
/// Transport-agnostic: works over any [SgtpTransport] (TCP, WebSocket, …).
/// The userdir multiplexing signal is 32 zero bytes sent immediately after
/// [connect]; the relay server routes the connection to the user directory
/// upon receiving them.
///
/// All frames are: u32 frame_len (big-endian) | u8 msg_type | payload.
/// Requests are sequential (no concurrent in-flight messages).
/// NOTIFY (0x86) is unsolicited and handled via [notifyStream].
class UserDirClient implements IUserDirClient {
  /// Human-readable label used in log output (e.g. "tcp://host:port").
  @override
  final String label;
  final SgtpTransport _transport;

  final _buf = <int>[];
  final _pending = <Completer<Uint8List?>>[];
  Future<void> _requestQueue = Future<void>.value();
  StreamController<UserDirMeta>? _notifyCtrl;
  StreamController<UserDirFriendNotify>? _friendNotifyCtrl;
  StreamSubscription<Uint8List>? _sub;
  var _closed = false;

  UserDirClient({required SgtpTransport transport, required this.label})
      : _transport = transport;

  /// Creates a [UserDirClient] for the given [node] using its configured
  /// transport and TLS settings. Returns null if no suitable transport is
  /// available in [opts] (run discovery first).
  static UserDirClient? forNode(NodeConfig node, SgtpServerOptions opts) {
    final useTls = node.useTls;
    // Resolve platform constraints (e.g. TCP → WebSocket on web).
    final preferred = SgtpTransportFamilyCodec.resolve(node.transport);
    final family = opts.supports(preferred, tls: useTls)
        ? preferred
        : (opts.supports(SgtpTransportFamily.tcp, tls: useTls)
            ? SgtpTransportFamily.tcp
            : null);
    if (family == null) return null;

    final port = opts.portFor(family, tls: useTls);
    if (port <= 0) return null;

    final scheme = switch (family) {
      SgtpTransportFamily.tcp => useTls ? 'tcps' : 'tcp',
      SgtpTransportFamily.websocket => useTls ? 'wss' : 'ws',
      SgtpTransportFamily.http => useTls ? 'https' : 'http',
    };
    final transport = switch (family) {
      SgtpTransportFamily.tcp => TcpSgtpTransport(
          host: node.host, port: port, useTls: useTls, fakeSni: node.fakeSni),
      SgtpTransportFamily.websocket => WebSocketSgtpTransport(
          host: node.host, port: port, useTls: useTls, fakeSni: node.fakeSni),
      SgtpTransportFamily.http => HttpSgtpTransport(
          host: node.host, port: port, useTls: useTls, fakeSni: node.fakeSni),
    };
    return UserDirClient(
        transport: transport, label: '$scheme://${node.host}:$port');
  }

  @override
  Stream<UserDirMeta> get notifyStream {
    _notifyCtrl ??= StreamController<UserDirMeta>.broadcast();
    return _notifyCtrl!.stream;
  }

  @override
  Stream<UserDirFriendNotify> get friendNotifyStream {
    _friendNotifyCtrl ??= StreamController<UserDirFriendNotify>.broadcast();
    return _friendNotifyCtrl!.stream;
  }

  @override
  bool get isConnected => !_closed && _transport.isConnected;

  /// Connect via the underlying transport and send the 32-byte zero magic
  /// prefix that signals userdir intent to the relay server.
  @override
  Future<void> connect() async {
    AppLogger.i('Connecting to $label', tag: _tag);
    await _transport.connect();

    _sub = _transport.inbound.listen(
      _onData,
      onError: (e) {
        AppLogger.e('$label — transport error: $e', tag: _tag);
        _fail();
      },
      onDone: () {
        if (!_closed) {
          AppLogger.w('$label — server closed the connection', tag: _tag);
        }
        _fail();
      },
      cancelOnError: true,
    );

    await _transport.send(Uint8List(32)); // userdir routing magic
    AppLogger.d('→ OUTBOUND  MAGIC          32B (zero routing prefix)',
        tag: _tag);
    AppLogger.i('Connected to $label', tag: _tag);
  }

  void _onData(Uint8List data) {
    final hex = data.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
    AppLogger.d('← RAW  ${data.length}B: $hex', tag: _tag);
    _buf.addAll(data);
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

    if (msgType == 0x88) {
      final evt = _parseFriendNotify(payload);
      AppLogger.d(
        '← INBOUND   ${_msgName(msgType).padRight(14)} ${payload.length}B',
        tag: _tag,
      );
      if (evt != null) _friendNotifyCtrl?.add(evt);
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
          final msg =
              msgLen > 0 ? utf8.decode(payload.sublist(4, 4 + msgLen)) : '';
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
    _friendNotifyCtrl?.close();
  }

  Future<Uint8List?> _send(int msgType, Uint8List payload) async {
    // SGTP userdir protocol expects a strict request/response sequence.
    // Serializing send operations avoids in-flight races and response mixups.
    final done = Completer<Uint8List?>();
    _requestQueue = _requestQueue.catchError((_) {}).then((_) async {
      if (_closed || !_transport.isConnected) {
        done.complete(null);
        return;
      }

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
      try {
        await _transport.send(frame);
      } catch (e) {
        _pending.remove(c);
        AppLogger.w('Send failed for ${_msgName(msgType)}: $e', tag: _tag);
        done.complete(null);
        return;
      }

      final resp = await c.future.timeout(
        const Duration(seconds: 15),
        onTimeout: () {
          AppLogger.w('${_msgName(msgType)} timed out', tag: _tag);
          _pending.remove(c);
          return null;
        },
      );
      done.complete(resp);
    });
    return done.future;
  }

  /// Registers (or updates) the caller's own profile on the server.
  ///
  /// [username] is optional; pass null to omit it.
  /// The payload is signed with [identityKeyPair] using Ed25519.
  Future<bool> register({
    required String? username,
    required String fullname,
    required Uint8List pubkey,
    required Uint8List avatarBytes,
    required SimpleKeyPairData identityKeyPair,
  }) async {
    final result = await registerWithResult(
      username: username,
      fullname: fullname,
      pubkey: pubkey,
      avatarBytes: avatarBytes,
      identityKeyPair: identityKeyPair,
    );
    return result.ok;
  }

  @override
  Future<({bool ok, int? errorCode, String? errorMessage})> registerWithResult({
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
        2 +
        usernameBytes.length +
        2 +
        fullnameBytes.length +
        32 + // pubkey
        4 +
        avatarLen +
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
    final sig = await Ed25519().sign(toSign, keyPair: identityKeyPair);
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
      return (ok: true, errorCode: null, errorMessage: null);
    } else {
      final err = _parseError(resp);
      AppLogger.w(
          'REGISTER failed  ${resp == null ? 'null' : _msgName(resp[0])}${_errorDetail(resp)}',
          tag: _tag);
      return (ok: false, errorCode: err.$1, errorMessage: err.$2);
    }
  }

  /// Fetches lightweight metadata (no avatar bytes) for [pubkey].
  /// Returns null on error or if the profile is not found.
  @override
  Future<UserDirMeta?> getMeta(Uint8List pubkey) async {
    final pk8 = pubkey
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join()
        .substring(0, 8);
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
  @override
  Future<UserDirProfile?> getProfile(Uint8List pubkey) async {
    final pk8 = pubkey
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join()
        .substring(0, 8);
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
  @override
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

  /// Searches userdir by username/fullname query.
  /// Returns zero or more lightweight metadata entries.
  @override
  Future<List<UserDirMeta>> search(String query, {int limit = 20}) async {
    final q = query.trim();
    if (q.isEmpty) return const [];
    final qBytes = utf8.encode(q);
    final safeLimit = limit.clamp(1, 100).toInt();

    // Common wire format: version(1) + query_len(u16) + query + limit(u16)
    final payload = Uint8List(1 + 2 + qBytes.length + 2);
    var o = 0;
    payload[o++] = 1; // version
    payload[o++] = (qBytes.length >> 8) & 0xff;
    payload[o++] = qBytes.length & 0xff;
    payload.setRange(o, o + qBytes.length, qBytes);
    o += qBytes.length;
    payload[o++] = (safeLimit >> 8) & 0xff;
    payload[o++] = safeLimit & 0xff;

    var resp = await _send(0x02, payload);
    if (resp == null || resp.isEmpty || resp[0] != 0x83) {
      // Fallback for servers that expect payload without explicit limit.
      final payloadNoLimit = Uint8List(1 + 2 + qBytes.length);
      var p = 0;
      payloadNoLimit[p++] = 1;
      payloadNoLimit[p++] = (qBytes.length >> 8) & 0xff;
      payloadNoLimit[p++] = qBytes.length & 0xff;
      payloadNoLimit.setRange(p, p + qBytes.length, qBytes);
      resp = await _send(0x02, payloadNoLimit);
    }
    if (resp == null || resp.isEmpty || resp[0] != 0x83) {
      AppLogger.w(
        'SEARCH failed "$q"  ${resp == null ? 'null' : _msgName(resp[0])}${_errorDetail(resp)}',
        tag: _tag,
      );
      return const [];
    }
    return _parseSearchResults(resp.sublist(1));
  }

  @override
  Future<bool> sendFriendRequest({
    required Uint8List myPubkey,
    required Uint8List peerPubkey,
    required SimpleKeyPairData identityKeyPair,
  }) async {
    final payload = Uint8List(1 + 32 + 32 + 1 + 64);
    payload[0] = 1;
    payload.setRange(1, 33, myPubkey);
    payload.setRange(33, 65, peerPubkey);
    payload[65] = 1; // sig_alg ed25519
    final signed = Uint8List(1 + payload.length - 64);
    signed[0] = 0x07;
    signed.setRange(1, signed.length, payload.sublist(0, payload.length - 64));
    final sig = await Ed25519().sign(signed, keyPair: identityKeyPair);
    payload.setRange(payload.length - 64, payload.length, sig.bytes);

    final resp = await _send(0x07, payload);
    return resp != null && resp.isNotEmpty && resp[0] == 0x81;
  }

  @override
  Future<bool> sendFriendResponse({
    required Uint8List myPubkey,
    required Uint8List requesterPubkey,
    required bool accept,
    required SimpleKeyPairData identityKeyPair,
  }) async {
    final payload = Uint8List(1 + 32 + 32 + 1 + 1 + 64);
    payload[0] = 1;
    payload.setRange(1, 33, myPubkey);
    payload.setRange(33, 65, requesterPubkey);
    payload[65] = accept ? 1 : 2;
    payload[66] = 1; // sig_alg ed25519
    final signed = Uint8List(1 + payload.length - 64);
    signed[0] = 0x08;
    signed.setRange(1, signed.length, payload.sublist(0, payload.length - 64));
    final sig = await Ed25519().sign(signed, keyPair: identityKeyPair);
    payload.setRange(payload.length - 64, payload.length, sig.bytes);

    final resp = await _send(0x08, payload);
    return resp != null && resp.isNotEmpty && resp[0] == 0x81;
  }

  @override
  Future<bool> sendFriendDelete({
    required Uint8List myPubkey,
    required Uint8List peerPubkey,
    required SimpleKeyPairData identityKeyPair,
  }) async {
    final payload = Uint8List(1 + 32 + 32 + 1 + 64);
    payload[0] = 1;
    payload.setRange(1, 33, myPubkey);
    payload.setRange(33, 65, peerPubkey);
    payload[65] = 1; // sig_alg ed25519
    final signed = Uint8List(1 + payload.length - 64);
    signed[0] = 0x0a;
    signed.setRange(1, signed.length, payload.sublist(0, payload.length - 64));
    final sig = await Ed25519().sign(signed, keyPair: identityKeyPair);
    payload.setRange(payload.length - 64, payload.length, sig.bytes);

    final resp = await _send(0x0a, payload);
    return resp != null && resp.isNotEmpty && resp[0] == 0x81;
  }

  @override
  Future<List<UserDirFriendState>?> friendSync({
    required Uint8List myPubkey,
    required SimpleKeyPairData identityKeyPair,
  }) async {
    final payload = Uint8List(1 + 32 + 1 + 64);
    payload[0] = 1;
    payload.setRange(1, 33, myPubkey);
    payload[33] = 1; // sig_alg ed25519
    final signed = Uint8List(1 + payload.length - 64);
    signed[0] = 0x09;
    signed.setRange(1, signed.length, payload.sublist(0, payload.length - 64));
    final sig = await Ed25519().sign(signed, keyPair: identityKeyPair);
    payload.setRange(payload.length - 64, payload.length, sig.bytes);

    final resp = await _send(0x09, payload);
    if (resp == null || resp.isEmpty || resp[0] != 0x87) return null;
    return _parseFriendSnapshot(resp.sublist(1));
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

  List<UserDirFriendState> _parseFriendSnapshot(Uint8List data) {
    try {
      var o = 0;
      if (data[o++] != 1) return const [];
      final count = (data[o] << 8) | data[o + 1];
      o += 2;
      final out = <UserDirFriendState>[];
      for (var i = 0; i < count; i++) {
        final peer = Uint8List.fromList(data.sublist(o, o + 32));
        o += 32;
        final status = data[o++];
        final hasRoom = data[o++] == 1;
        Uint8List? room;
        if (hasRoom) {
          room = Uint8List.fromList(data.sublist(o, o + 16));
          o += 16;
        }
        out.add(UserDirFriendState(
          peerPubkey: peer,
          status: status,
          roomUUID: room,
        ));
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  UserDirFriendNotify? _parseFriendNotify(Uint8List data) {
    try {
      var o = 0;
      if (data[o++] != 1) return null;
      final eventType = data[o++];
      final actor = Uint8List.fromList(data.sublist(o, o + 32));
      o += 32;
      final status = data[o++];
      final hasRoom = data[o++] == 1;
      Uint8List? room;
      if (hasRoom) {
        room = Uint8List.fromList(data.sublist(o, o + 16));
      }
      return UserDirFriendNotify(
        eventType: eventType,
        status: status,
        actorPubkey: actor,
        roomUUID: room,
      );
    } catch (_) {
      return null;
    }
  }

  List<UserDirMeta> _parseSearchResults(Uint8List data) {
    // Fast-path: some servers may return a single META-like payload.
    final single = _parseMeta(data);
    if (single != null) return [single];

    // SEARCH_RESULTS list format:
    // version(1) + count(u16) + count * entry
    // entry: pubkey(32) + username_len(u16) + username + fullname_len(u16)
    //        + fullname + avatar_sha256(32) [+ updated_at(u64, optional)]
    try {
      if (data.length < 3) return const [];
      var o = 0;
      final version = data[o++];
      if (version != 1) return const [];
      final count = _readU16(data, o);
      o += 2;

      final out = <UserDirMeta>[];
      for (var i = 0; i < count; i++) {
        if (o + 32 + 2 > data.length) break;
        final pubkey = Uint8List.fromList(data.sublist(o, o + 32));
        o += 32;

        final usernameLen = _readU16(data, o);
        o += 2;
        if (o + usernameLen + 2 > data.length) break;
        final username = utf8.decode(data.sublist(o, o + usernameLen));
        o += usernameLen;

        final fullnameLen = _readU16(data, o);
        o += 2;
        if (o + fullnameLen + 32 > data.length) break;
        final fullname = utf8.decode(data.sublist(o, o + fullnameLen));
        o += fullnameLen;

        final avatarSha256 = Uint8List.fromList(data.sublist(o, o + 32));
        o += 32;
        var updatedAt = 0;
        if (o + 8 <= data.length) {
          updatedAt = _readU64(data, o);
          o += 8;
        }

        out.add(UserDirMeta(
          pubkey: pubkey,
          username: username,
          fullname: fullname,
          avatarSha256: avatarSha256,
          updatedAt: updatedAt,
        ));
      }
      return out;
    } catch (_) {
      return const [];
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
      final msg = msgLen > 0 ? utf8.decode(payload.sublist(4, 4 + msgLen)) : '';
      return '  code=0x${code.toRadixString(16).padLeft(4, '0')} "$msg"';
    } catch (_) {
      return '';
    }
  }

  (int?, String?) _parseError(Uint8List? resp) {
    if (resp == null || resp.isEmpty || resp[0] != 0x82) {
      return (null, null);
    }
    try {
      final payload = resp.sublist(1);
      if (payload.length < 4) return (null, null);
      final code = (payload[0] << 8) | payload[1];
      final msgLen = (payload[2] << 8) | payload[3];
      final msg = msgLen > 0 ? utf8.decode(payload.sublist(4, 4 + msgLen)) : '';
      return (code, msg);
    } catch (_) {
      return (null, null);
    }
  }

  int _readU64(Uint8List data, int offset) {
    var result = 0;
    for (var i = 0; i < 8; i++) {
      result = (result << 8) | data[offset + i];
    }
    return result;
  }

  int _readU16(Uint8List data, int offset) =>
      (data[offset] << 8) | data[offset + 1];

  @override
  void close() {
    if (_closed) return;
    AppLogger.i('$label — closed by client', tag: _tag);
    _closed = true;
    _sub?.cancel();
    _transport.close();
    _notifyCtrl?.close();
    _friendNotifyCtrl?.close();
  }
}
