import 'dart:io';

import 'package:http/io_client.dart';

class DiscoveryHttpResponse {
  final int statusCode;
  final String body;

  const DiscoveryHttpResponse({required this.statusCode, required this.body});
}

Future<DiscoveryHttpResponse> httpGetDiscovery(
  Uri uri, {
  required Duration timeout,
}) async {
  final ioHttpClient = HttpClient()
    ..connectionTimeout = timeout
    ..badCertificateCallback = (_, __, ___) => true;
  final client = IOClient(ioHttpClient);
  try {
    final res = await client
        .get(uri, headers: const {'Accept': 'application/json'})
        .timeout(timeout);
    return DiscoveryHttpResponse(statusCode: res.statusCode, body: res.body);
  } finally {
    client.close();
  }
}
