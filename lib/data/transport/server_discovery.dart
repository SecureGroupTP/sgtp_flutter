import 'dart:async';
import 'dart:io';

import '../../core/sgtp_server_options.dart';

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
    final client = HttpClient()
      ..connectionTimeout = timeout
      ..badCertificateCallback = (_, __, ___) => true; // accept self-signed

    try {
      final req = await client.getUrl(uri).timeout(timeout);
      req.headers.set('Accept', 'application/json');
      final res = await req.close().timeout(timeout);
      if (res.statusCode != 200) {
        await res.drain<void>();
        throw HttpException('HTTP ${res.statusCode}', uri: uri);
      }
      final body = await res
          .transform(const SystemEncoding().decoder)
          .join()
          .timeout(timeout);
      return SgtpServerOptions.fromJsonString(body);
    } finally {
      client.close(force: true);
    }
  }
}
