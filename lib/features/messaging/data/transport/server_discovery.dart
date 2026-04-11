import 'dart:async';
import 'dart:convert';

import 'package:sgtp_flutter/core/sgtp_server_options.dart';
import 'package:sgtp_flutter/core/network/transport/discovery_http_client.dart';

class SgtpServerDiscovery {
  /// Discovers server options via HTTP(S) GET `/sgtp/discovery`.
  ///
  /// Tries the default discovery ports in strict order:
  /// 1) HTTPS 443
  /// 2) HTTP 80
  /// 3) HTTP 77
  /// Throws if all attempts fail.
  static Future<({SgtpServerOptions opts, int port, bool tls})> discover(
    String host, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final attempts = <({int port, bool tls})>[
      (port: 443, tls: true),
      (port: 80, tls: false),
      (port: 77, tls: false),
    ];
    Object? lastError;
    for (final a in attempts) {
      try {
        final opts = await _get(host, a.port, tls: a.tls, timeout: timeout);
        return (opts: opts, port: a.port, tls: a.tls);
      } catch (e) {
        lastError = e;
      }
    }
    throw StateError('Discovery failed for $host: $lastError');
  }

  static Future<SgtpServerOptions> _get(
    String host,
    int port, {
    required bool tls,
    required Duration timeout,
  }) async {
    final uri = Uri(
      scheme: tls ? 'https' : 'http',
      host: host,
      port: port,
      path: '/sgtp/discovery',
    );
    final res = await httpGetDiscovery(uri, timeout: timeout);
    if (res.statusCode != 200) {
      throw StateError('Discovery HTTP ${res.statusCode} for $uri');
    }

    final ct = res.contentType.toLowerCase();
    if (ct.contains('cbor')) {
      return SgtpServerOptions.fromCbor(res.body);
    }
    // Fallback: treat as JSON
    return SgtpServerOptions.fromJsonString(utf8.decode(res.body));
  }
}
