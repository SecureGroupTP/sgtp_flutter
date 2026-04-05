import 'package:http/http.dart' as http;

class DiscoveryHttpResponse {
  final int statusCode;
  final String body;

  const DiscoveryHttpResponse({required this.statusCode, required this.body});
}

Future<DiscoveryHttpResponse> httpGetDiscovery(
  Uri uri, {
  required Duration timeout,
}) async {
  final res = await http
      .get(uri, headers: const {'Accept': 'application/json'})
      .timeout(timeout);
  return DiscoveryHttpResponse(statusCode: res.statusCode, body: res.body);
}

