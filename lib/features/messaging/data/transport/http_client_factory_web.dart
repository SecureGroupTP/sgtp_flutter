import 'package:http/http.dart' as http;

http.Client createSgtpHttpClient({
  required String host,
  required int port,
  required bool useTls,
  String? fakeSni,
}) =>
    http.Client();
