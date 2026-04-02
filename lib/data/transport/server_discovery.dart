import 'dart:async';

import '../../core/sgtp_server_options.dart';
import 'server_discovery_http_client.dart';

class SgtpServerDiscovery {
  static final _ipv4Re = RegExp(r'^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$');

  /// Discovers server options via HTTP(S) GET `/sgtp/discovery`.
  ///
  /// For domain names, tries HTTPS on port 443 first, then HTTP on port 80.
  /// For IP addresses, only tries HTTP on port 80 (no TLS cert to validate).
  /// Throws if all attempts fail.
  static Future<({SgtpServerOptions opts, int port, bool tls})> discover(
    String host, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final isDomain = !_ipv4Re.hasMatch(host);

    if (isDomain) {
      try {
        final opts = await _get(host, 443, tls: true, timeout: timeout);
        return (opts: opts, port: 443, tls: true);
      } catch (_) {}
    }

    final opts = await _get(host, 80, tls: false, timeout: timeout);
    return (opts: opts, port: 80, tls: false);
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
    return SgtpServerOptions.fromJsonString(res.body);
  }
}
