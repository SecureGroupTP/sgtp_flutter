import 'dart:typed_data';

import 'package:http/http.dart' as http;

class DiscoveryHttpResponse {
  final int statusCode;
  final Uint8List body;
  final String contentType;

  const DiscoveryHttpResponse({
    required this.statusCode,
    required this.body,
    required this.contentType,
  });
}

Future<DiscoveryHttpResponse> httpGetDiscovery(
  Uri uri, {
  required Duration timeout,
}) async {
  final res = await http
      .get(uri, headers: const {'Accept': 'application/cbor, application/json'})
      .timeout(timeout);
  return DiscoveryHttpResponse(
    statusCode: res.statusCode,
    body: res.bodyBytes,
    contentType: res.headers['content-type'] ?? '',
  );
}
