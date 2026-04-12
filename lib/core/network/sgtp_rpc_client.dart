import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cbor/cbor.dart';
import 'package:cryptography/cryptography.dart';

import 'package:sgtp_flutter/core/app_logger.dart';
import 'package:sgtp_flutter/core/network/i_protocol_transport.dart';
import 'package:sgtp_flutter/core/network/rpc_models/auth_rpc_models.dart';
import 'package:sgtp_flutter/core/network/rpc_models/rpc_request.dart';
import 'package:sgtp_flutter/core/uuid_v7.dart';

const _tag = 'RPC';

/// CBOR-RPC caller that sits on top of [IProtocolTransport].
///
/// Each [callRpc] encodes the request as a signed CBOR packet and awaits the
/// matching response (matched by [replyToRequestId]).
///
/// Encoding rules:
///   - UUIDs         → bstr (16 bytes)
///   - Datetimes     → uint (microseconds since Unix epoch)
///   - Enums         → uint (integer value)
class _QueuedCall {
  _QueuedCall(this.request, this.completer);
  final RpcRequest request;
  final Completer<Map<String, dynamic>> completer;
}

class SgtpRpcClient {
  final IProtocolTransport _transport;

  SimpleKeyPairData? _keyPair;
  bool _authenticated = false;

  final _pending = <String, Completer<Map<String, dynamic>>>{};
  final _queue = <_QueuedCall>[];

  SgtpRpcClient(IProtocolTransport transport) : _transport = transport {
    transport.registerPacketCallback(_onPacket);
  }

  IProtocolTransport get transport => _transport;
  bool get hasCredentials => _keyPair != null;

  /// Performs the full Ed25519 challenge-response handshake.
  ///
  /// No-ops if already authenticated. Sets signing key, exchanges challenge,
  /// then marks the session authenticated and flushes the send queue.
  /// Returns an error string on failure, or null on success.
  Future<String?> authenticate(
    Uint8List publicKey,
    SimpleKeyPairData keyPair,
  ) async {
    if (_authenticated) return null;
    try {
      _keyPair = keyPair;
      final challengeReq = RequestAuthChallengeRequest(
        userPublicKey: publicKey,
        publicIp: '',
        deviceId: 'flutter-client',
        clientNonce: _randomBytes(32),
      );
      final challengeRaw = await callRpc(challengeReq);
      final challengeRes = RequestAuthChallengeResponse.fromMap(challengeRaw);

      final sig = await Ed25519().sign(challengeRes.challengePayload, keyPair: keyPair);
      final solveReq = SolveAuthChallengeRequest(
        sessionId: challengeRes.sessionId,
        signature: Uint8List.fromList(sig.bytes),
      );
      final solveRaw = await callRpc(solveReq);
      final solveRes = SolveAuthChallengeResponse.fromMap(solveRaw);

      if (!solveRes.isAuthenticated) return 'Authentication rejected by server';

      _keyPair = keyPair;
      _authenticated = true;
      _flushQueue();
      AppLogger.d('Authenticated as ${_hexShort(publicKey)}', tag: _tag);
      return null;
    } catch (e, st) {
      AppLogger.e('authenticate failed: $e\n$st', tag: _tag);
      return 'Authentication failed: $e';
    }
  }

  /// Mark the session as authenticated and flush the send queue.
  ///
  /// Use this only when credentials are known to be valid without a challenge
  /// (e.g. reconnect with a cached session token).
  void setCredentials(Uint8List publicKey, SimpleKeyPairData keyPair) {
    _keyPair = keyPair;
    _authenticated = true;
    _flushQueue();
  }

  void _flushQueue() {
    final queued = List<_QueuedCall>.from(_queue);
    _queue.clear();
    for (final call in queued) {
      _sendRpc(call.request).then(
        call.completer.complete,
        onError: call.completer.completeError,
      );
    }
  }

  /// Register a callback for server-initiated events (not RPC responses).
  /// Stub — not yet implemented; events are silently ignored.
  // ignore: avoid_unused_parameters
  void registerEventsCallback(
      void Function(Map<String, dynamic> event) callback) {}

  /// Send a typed RPC request and return the decoded response parameters.
  ///
  /// If [RpcRequest.requiresAuth] is true and authentication has not yet
  /// completed, the call is held in an internal queue and dispatched
  /// automatically once [setCredentials] is called. The returned [Future]
  /// resolves when the server response arrives (or times out).
  Future<Map<String, dynamic>> callRpc(RpcRequest request) {
    if (request.requiresAuth && !_authenticated) {
      final completer = Completer<Map<String, dynamic>>();
      _queue.add(_QueuedCall(request, completer));
      AppLogger.d('queued ${request.method} (waiting for auth)', tag: _tag);
      return completer.future;
    }
    return _sendRpc(request);
  }

  Future<Map<String, dynamic>> _sendRpc(RpcRequest request) async {
    final requestId = generateUUIDv7();
    final requestIdHex = uuidBytesToHex(requestId);

    final payloadMap = CborMap({
      CborString('requestId'): CborBytes(requestId),
      CborString('rpcCall'): CborString(request.method),
      CborString('timestamp'):
          CborSmallInt(DateTime.now().millisecondsSinceEpoch),
      CborString('version'): CborSmallInt(1),
      CborString('parameters'): _toCborValue(request.toMap()),
    });

    final payloadBytes = cbor.encode(payloadMap);

    Uint8List signature;
    final kp = _keyPair;
    if (kp != null) {
      final algorithm = Ed25519();
      final sig = await algorithm.sign(payloadBytes, keyPair: kp);
      signature = Uint8List.fromList(sig.bytes);
    } else {
      signature = Uint8List(64);
    }

    final packet = CborMap({
      CborString('signature'): CborBytes(signature),
      CborString('payload'): payloadMap,
    });
    final packetBytes = Uint8List.fromList(cbor.encode(packet));

    _logCbor('→', requestIdHex, packet, packetBytes);

    final completer = Completer<Map<String, dynamic>>();
    _pending[requestIdHex] = completer;

    try {
      await _transport.send(packetBytes);
    } catch (e) {
      _pending.remove(requestIdHex);
      rethrow;
    }

    return completer.future.timeout(
      const Duration(seconds: 30),
      onTimeout: () {
        _pending.remove(requestIdHex);
        throw TimeoutException(
            'RPC timeout: ${request.method}', const Duration(seconds: 30));
      },
    );
  }

  // ── Internal ───────────────────────────────────────────────────────────────

  void _onPacket(Uint8List bytes) {
    // Log every inbound packet immediately — before any routing.
    _logRaw('←', bytes);
    try {
      final decoded = cbor.decode(bytes);
      final packets = switch (decoded) {
        CborMap() => [decoded],
        CborList() => decoded.whereType<CborMap>().toList(),
        _ => const <CborMap>[],
      };
      for (final packet in packets) {
        _onResponsePacket(packet, bytes);
      }
    } catch (e, st) {
      // Packet parse error — silently discard to not break other pending calls.
      // ignore: avoid_print
      Zone.current.handleUncaughtError(e, st);
    }
  }

  void _onResponsePacket(CborMap decoded, Uint8List rawBytes) {
    final replyToIdValue = decoded[CborString('replyToRequestId')];
    if (replyToIdValue == null || replyToIdValue is CborNull) {
      // Server-initiated event — ignored until events callback is wired.
      return;
    }

    final replyIdBytes = switch (replyToIdValue) {
      CborBytes() => replyToIdValue.bytes,
      CborString() => hexToBytes(replyToIdValue.toString().replaceAll('-', '')),
      _ => null,
    };
    if (replyIdBytes == null) {
      AppLogger.w('replyToRequestId has unexpected type: ${replyToIdValue.runtimeType}', tag: _tag);
      return;
    }
    final replyIdHex =
        replyIdBytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

    final completer = _pending.remove(replyIdHex);
    if (completer == null) {
      AppLogger.w('no pending call for replyId=$replyIdHex', tag: _tag);
      return;
    }

    final paramsValue = decoded[CborString('parameters')];
    if (paramsValue is CborMap) {
      final params = _fromCborMap(paramsValue);
      final error = params['error'];
      if (error is Map<String, dynamic>) {
        completer.completeError(StateError(
            '${error['code'] ?? 'rpc_error'}: ${error['message'] ?? ''}'));
      } else {
        completer.complete(params);
      }
    } else {
      completer.completeError(
        StateError('Invalid RPC response parameters for reply $replyIdHex'),
      );
    }
  }

  // ── Logging ────────────────────────────────────────────────────────────────

  /// Logs raw inbound bytes as base64, with best-effort CBOR→JSON decoding.
  static void _logRaw(String dir, Uint8List bytes) {
    final b64 = base64.encode(bytes);
    String decoded;
    try {
      final value = cbor.decode(bytes);
      decoded = _jsonEncode(value is CborMap
          ? _cborToJsonLog(value)
          : value is CborList
              ? value.map((e) => e is CborMap ? _cborToJsonLog(e) : e.toString()).toList()
              : value.toString());
    } catch (_) {
      decoded = '<parse error>';
    }
    AppLogger.d('$dir raw $decoded\n  cbor=$b64', tag: _tag);
  }

  /// Logs a full CBOR packet (request or response) as JSON + raw base64.
  /// [dir] is `'→'` for outgoing, `'←'` for incoming.
  /// [idHex] is the requestId for outgoing (first 8 chars shown), null for incoming.
  static void _logCbor(
      String dir, String? idHex, CborMap packet, Uint8List rawBytes) {
    final label = idHex != null
        ? '$dir [${idHex.substring(0, idHex.length >= 8 ? 8 : idHex.length)}]'
        : dir;
    final b64 = base64.encode(rawBytes);
    AppLogger.d(
      '$label ${_jsonEncode(_cborToJsonLog(packet))}\n  cbor=$b64',
      tag: _tag,
    );
  }

  /// Recursively converts a [CborValue] to a JSON-encodable value.
  /// Byte arrays are rendered as hex strings with truncation for long arrays.
  static dynamic _cborToJsonLog(CborValue value) {
    return switch (value) {
      CborNull() => null,
      CborBool() => value.value,
      CborSmallInt() => value.value,
      CborInt() => value.toInt(),
      CborString() => value.toString(),
      CborBytes() => _bytesToLogString(Uint8List.fromList(value.bytes)),
      CborMap() => {
          for (final e in value.entries)
            (e.key is CborString
                    ? (e.key as CborString).toString()
                    : e.key.toString()):
                _cborToJsonLog(e.value),
        },
      CborList() => value.map(_cborToJsonLog).toList(),
      _ => value.toString(),
    };
  }

  /// Formats bytes as hex; truncates if longer than 20 bytes:
  /// `<first 2 bytes hex>..<count-4> bytes..<last 2 bytes hex>`.
  static String _bytesToLogString(Uint8List bytes) {
    if (bytes.isEmpty) return '';
    String hex(List<int> b) =>
        b.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
    if (bytes.length <= 20) return hex(bytes);
    final head = hex(bytes.sublist(0, 2));
    final tail = hex(bytes.sublist(bytes.length - 2));
    final middle = bytes.length - 4;
    return '$head..$middle bytes..$tail';
  }

  static String _jsonEncode(dynamic value) {
    try {
      return jsonEncode(value);
    } catch (_) {
      return value.toString();
    }
  }

  // ── Private helpers ────────────────────────────────────────────────────────

  static final _rng = Random.secure();

  static Uint8List _randomBytes(int length) =>
      Uint8List.fromList(List.generate(length, (_) => _rng.nextInt(256)));

  static String _hexShort(Uint8List key) =>
      key.map((b) => b.toRadixString(16).padLeft(2, '0')).join().substring(0, 8);

  // ── CBOR helpers ───────────────────────────────────────────────────────────

  static CborValue _toCborValue(dynamic value) {
    if (value == null) return const CborNull();
    if (value is String) return CborString(value);
    if (value is bool) return CborBool(value);
    if (value is int) return CborSmallInt(value);
    if (value is Uint8List) return CborBytes(value);
    if (value is List<int>) return CborBytes(Uint8List.fromList(value));
    if (value is Map) {
      return CborMap({
        for (final e in value.entries)
          _toCborValue(e.key): _toCborValue(e.value),
      });
    }
    if (value is List) {
      return CborList(value.map(_toCborValue).toList());
    }
    return CborString(value.toString());
  }

  static Map<String, dynamic> _fromCborMap(CborMap map) {
    final result = <String, dynamic>{};
    for (final entry in map.entries) {
      final key = entry.key;
      final keyStr = key is CborString ? key.toString() : key.toString();
      result[keyStr] = _fromCborValue(entry.value);
    }
    return result;
  }

  static dynamic _fromCborValue(CborValue value) {
    return switch (value) {
      CborNull() => null,
      CborBool() => value.value,
      CborSmallInt() => value.value,
      CborInt() => value.toInt(),
      CborString() => value.toString(),
      CborBytes() => Uint8List.fromList(value.bytes),
      CborMap() => _fromCborMap(value),
      CborList() => value.map(_fromCborValue).toList(),
      _ => null,
    };
  }
}
