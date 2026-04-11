import 'dart:convert';
import 'dart:typed_data';

import 'package:cbor/cbor.dart';
import 'package:sgtp_flutter/core/sgtp_transport.dart';

class SgtpServerOptions {
  final bool tcp;
  final bool tcpTls;
  final bool http;
  final bool httpTls;
  final bool websocket;
  final bool websocketTls;

  final int tcpPort;
  final int tcpTlsPort;
  final int httpPort;
  final int httpTlsPort;
  final int websocketPort;
  final int websocketTlsPort;

  const SgtpServerOptions({
    required this.tcp,
    required this.tcpTls,
    required this.http,
    required this.httpTls,
    required this.websocket,
    required this.websocketTls,
    required this.tcpPort,
    required this.tcpTlsPort,
    required this.httpPort,
    required this.httpTlsPort,
    required this.websocketPort,
    required this.websocketTlsPort,
  });

  static const int wireBytesLength = 25;

  static SgtpServerOptions fromJson(Map<String, dynamic> json) {
    if (_hasFlatDiscoveryPorts(json)) {
      final tcpPort = _flatPort(json, 'tcp_port');
      final tcpTlsPort = _flatPort(json, 'tcp_tls_port');
      final httpPort = _flatPort(json, 'http_port');
      final httpTlsPort = _flatPort(json, 'https_port');
      final websocketPort = _flatPort(json, 'ws_port');
      final websocketTlsPort = _flatPort(json, 'wss_port');
      return SgtpServerOptions(
        tcp: tcpPort > 0,
        tcpTls: tcpTlsPort > 0,
        http: httpPort > 0,
        httpTls: httpTlsPort > 0,
        websocket: websocketPort > 0,
        websocketTls: websocketTlsPort > 0,
        tcpPort: tcpPort,
        tcpTlsPort: tcpTlsPort,
        httpPort: httpPort,
        httpTlsPort: httpTlsPort,
        websocketPort: websocketPort,
        websocketTlsPort: websocketTlsPort,
      );
    }

    final ports = (json['ports'] as Map<String, dynamic>?) ?? {};
    final enabled = (json['enabled'] as Map<String, dynamic>?) ?? {};

    int p(String key) => (ports[key] as num?)?.toInt() ?? 0;
    bool e(String key) => (enabled[key] as bool?) ?? false;

    return SgtpServerOptions(
      tcp: e('tcp'),
      tcpTls: e('tcp_tls'),
      http: e('http'),
      httpTls: e('http_tls'),
      websocket: e('ws'),
      websocketTls: e('ws_tls'),
      tcpPort: p('tcp'),
      tcpTlsPort: p('tcp_tls'),
      httpPort: p('http'),
      httpTlsPort: p('http_tls'),
      websocketPort: p('ws'),
      websocketTlsPort: p('ws_tls'),
    );
  }

  static bool _hasFlatDiscoveryPorts(Map<String, dynamic> json) {
    return json.containsKey('tcp_port') ||
        json.containsKey('tcp_tls_port') ||
        json.containsKey('http_port') ||
        json.containsKey('https_port') ||
        json.containsKey('ws_port') ||
        json.containsKey('wss_port');
  }

  static int _flatPort(Map<String, dynamic> json, String key) =>
      (json[key] as num?)?.toInt() ?? 0;

  static SgtpServerOptions fromJsonString(String body) =>
      fromJson(json.decode(body) as Map<String, dynamic>);

  /// Parse from CBOR-encoded bytes.
  /// Expects a CBOR map with the same structure as the JSON format:
  /// `{ports: {tcp: int, ...}, enabled: {tcp: bool, ...}}`.
  static SgtpServerOptions fromCbor(Uint8List bytes) {
    final decoded = cbor.decode(bytes);
    if (decoded is! CborMap) {
      throw FormatException('Discovery response is not a CBOR map');
    }

    Map<String, dynamic> cborMapToJson(CborMap map) {
      final result = <String, dynamic>{};
      for (final entry in map.entries) {
        final key = entry.key;
        final value = entry.value;
        final keyStr = key is CborString ? key.toString() : key.toString();
        result[keyStr] = switch (value) {
          CborString() => value.toString(),
          CborSmallInt() => value.value,
          CborInt() => value.toInt(),
          CborBool() => value.value,
          CborMap() => cborMapToJson(value),
          CborNull() => null,
          _ => null,
        };
      }
      return result;
    }

    return fromJson(cborMapToJson(decoded));
  }

  static SgtpServerOptions fromBytes(Uint8List bytes) {
    if (bytes.length != wireBytesLength) {
      throw ArgumentError(
          'Expected $wireBytesLength bytes, got ${bytes.length}');
    }

    final flags = bytes[0];
    int portAt(int idx) {
      final off = 1 + idx * 4;
      final b0 = bytes[off];
      final b1 = bytes[off + 1];
      final b2 = bytes[off + 2];
      final b3 = bytes[off + 3];
      final v = (b0 << 24) | (b1 << 16) | (b2 << 8) | b3;
      return v;
    }

    return SgtpServerOptions(
      tcp: (flags & (1 << 0)) != 0,
      tcpTls: (flags & (1 << 1)) != 0,
      http: (flags & (1 << 2)) != 0,
      httpTls: (flags & (1 << 3)) != 0,
      websocket: (flags & (1 << 4)) != 0,
      websocketTls: (flags & (1 << 5)) != 0,
      tcpPort: portAt(0),
      tcpTlsPort: portAt(1),
      httpPort: portAt(2),
      httpTlsPort: portAt(3),
      websocketPort: portAt(4),
      websocketTlsPort: portAt(5),
    );
  }

  Uint8List toBytes() {
    final out = Uint8List(wireBytesLength);
    var flags = 0;
    if (tcp) flags |= 1 << 0;
    if (tcpTls) flags |= 1 << 1;
    if (http) flags |= 1 << 2;
    if (httpTls) flags |= 1 << 3;
    if (websocket) flags |= 1 << 4;
    if (websocketTls) flags |= 1 << 5;
    out[0] = flags & 0xff;

    void putPort(int idx, int value) {
      final off = 1 + idx * 4;
      final v = value & 0xffffffff;
      out[off] = (v >> 24) & 0xff;
      out[off + 1] = (v >> 16) & 0xff;
      out[off + 2] = (v >> 8) & 0xff;
      out[off + 3] = v & 0xff;
    }

    putPort(0, tcpPort);
    putPort(1, tcpTlsPort);
    putPort(2, httpPort);
    putPort(3, httpTlsPort);
    putPort(4, websocketPort);
    putPort(5, websocketTlsPort);
    return out;
  }

  bool supports(SgtpTransportFamily family, {required bool tls}) {
    return switch (family) {
      SgtpTransportFamily.tcp => tls ? tcpTls : tcp,
      SgtpTransportFamily.http => tls ? httpTls : http,
      SgtpTransportFamily.websocket => tls ? websocketTls : websocket,
    };
  }

  int portFor(SgtpTransportFamily family, {required bool tls}) {
    return switch (family) {
      SgtpTransportFamily.tcp => tls ? tcpTlsPort : tcpPort,
      SgtpTransportFamily.http => tls ? httpTlsPort : httpPort,
      SgtpTransportFamily.websocket => tls ? websocketTlsPort : websocketPort,
    };
  }

  bool get hasAny =>
      tcp || tcpTls || http || httpTls || websocket || websocketTls;

  List<String> availableLabels() {
    final out = <String>[];
    if (tcp) out.add('TCP');
    if (tcpTls) out.add('TCP+TLS');
    if (http) out.add('HTTP');
    if (httpTls) out.add('HTTP+TLS');
    if (websocket) out.add('WebSocket');
    if (websocketTls) out.add('WebSocket+TLS');
    return out;
  }

  @override
  String toString() => 'SgtpServerOptions(${availableLabels().join(", ")})';
}
