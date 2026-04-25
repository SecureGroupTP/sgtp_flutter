import 'dart:async';
import 'dart:convert';

import 'package:sgtp_flutter/core/sgtp_server_options.dart';
import 'package:sgtp_flutter/core/network/transport/discovery_http_client.dart';

class SgtpServerDiscovery {
  /// Discovers server options via HTTP(S) GET `/api/v1/discovery`.
  ///
  /// Tries an explicitly supplied port first, then default discovery ports:
  /// 1) HTTPS 443
  /// 2) HTTP 80
  /// Throws if all attempts fail.
  static Future<({SgtpServerOptions opts, int port, bool tls})> discover(
    String host, {
    int? preferredPort,
    bool? preferredTls,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final cleanHost = _stripPort(host);
    final explicitPort = preferredPort ?? _portFromHost(host);
    final attempts = explicitPort != null && explicitPort > 0
        ? <({int port, bool tls})>[
            (port: explicitPort, tls: preferredTls ?? false),
          ]
        : <({int port, bool tls})>[
            (port: 443, tls: true),
            (port: 80, tls: false),
          ];
    Object? lastError;
    for (final a in _dedupeAttempts(attempts)) {
      try {
        final opts =
            await _get(cleanHost, a.port, tls: a.tls, timeout: timeout);
        return (opts: opts, port: a.port, tls: a.tls);
      } catch (e) {
        lastError = e;
      }
    }
    throw StateError('Discovery failed for $cleanHost: $lastError');
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
      path: '/api/v1/discovery/',
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

  static List<({int port, bool tls})> _dedupeAttempts(
    List<({int port, bool tls})> attempts,
  ) {
    final seen = <String>{};
    final out = <({int port, bool tls})>[];
    for (final attempt in attempts) {
      final key = '${attempt.tls}:${attempt.port}';
      if (seen.add(key)) out.add(attempt);
    }
    return out;
  }

  static String _stripPort(String raw) {
    final host = raw.trim();
    if (host.startsWith('[')) {
      final end = host.indexOf(']');
      return end > 0 ? host.substring(1, end) : host;
    }
    final colon = host.lastIndexOf(':');
    if (colon <= 0 || colon == host.length - 1) return host;
    final maybePort = int.tryParse(host.substring(colon + 1));
    return maybePort == null ? host : host.substring(0, colon);
  }

  static int? _portFromHost(String raw) {
    final host = raw.trim();
    if (host.startsWith('[')) {
      final end = host.indexOf(']');
      if (end <= 0 || end + 1 >= host.length || host[end + 1] != ':') {
        return null;
      }
      return int.tryParse(host.substring(end + 2));
    }
    final colon = host.lastIndexOf(':');
    if (colon <= 0 || colon == host.length - 1) return null;
    return int.tryParse(host.substring(colon + 1));
  }
}
