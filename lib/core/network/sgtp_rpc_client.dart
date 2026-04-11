import 'dart:async';
import 'dart:typed_data';

import 'package:cbor/cbor.dart';
import 'package:cryptography/cryptography.dart';

import 'package:sgtp_flutter/core/network/i_protocol_transport.dart';
import 'package:sgtp_flutter/core/network/rpc_models/rpc_request.dart';
import 'package:sgtp_flutter/core/uuid_v7.dart';

/// CBOR-RPC caller that sits on top of [IProtocolTransport].
///
/// Each [callRpc] encodes the request as a signed CBOR packet and awaits the
/// matching response (matched by [replyToRequestId]).
///
/// Encoding rules:
///   - UUIDs         → bstr (16 bytes)
///   - Datetimes     → uint (microseconds since Unix epoch)
///   - Enums         → uint (integer value)
class SgtpRpcClient {
  final IProtocolTransport _transport;

  SimpleKeyPairData? _keyPair;

  final _pending = <String, Completer<Map<String, dynamic>>>{};

  SgtpRpcClient(IProtocolTransport transport) : _transport = transport {
    transport.registerPacketCallback(_onPacket);
  }

  IProtocolTransport get transport => _transport;
  bool get hasCredentials => _keyPair != null;

  /// Set the signing credentials used for authenticated RPC calls.
  void setCredentials(Uint8List publicKey, SimpleKeyPairData keyPair) {
    _keyPair = keyPair;
  }

  /// Register a callback for server-initiated events (not RPC responses).
  /// Stub — not yet implemented; events are silently ignored.
  // ignore: avoid_unused_parameters
  void registerEventsCallback(void Function(Map<String, dynamic> event) callback) {}

  /// Encode and send a typed RPC request; returns the decoded [parameters] map
  /// from the matching response.
  ///
  /// Throws [TimeoutException] if no response arrives within 30 seconds.
  Future<Map<String, dynamic>> callRpc(RpcRequest request) async {
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
        throw TimeoutException('RPC timeout: ${request.method}', const Duration(seconds: 30));
      },
    );
  }

  // ── Internal ───────────────────────────────────────────────────────────────

  void _onPacket(Uint8List bytes) {
    try {
      final decoded = cbor.decode(bytes);
      if (decoded is! CborMap) return;

      final replyToIdValue = decoded[CborString('replyToRequestId')];
      if (replyToIdValue == null || replyToIdValue is CborNull) {
        // Server-initiated event — ignored until events callback is wired.
        return;
      }

      final replyIdBytes = (replyToIdValue as CborBytes).bytes;
      final replyIdHex =
          replyIdBytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

      final completer = _pending.remove(replyIdHex);
      if (completer == null) return;

      final paramsValue = decoded[CborString('parameters')];
      if (paramsValue is CborMap) {
        completer.complete(_fromCborMap(paramsValue));
      } else {
        completer.completeError(
          StateError('Invalid RPC response parameters for reply $replyIdHex'),
        );
      }
    } catch (e, st) {
      // Packet parse error — silently discard to not break other pending calls.
      // ignore: avoid_print
      Zone.current.handleUncaughtError(e, st);
    }
  }

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
