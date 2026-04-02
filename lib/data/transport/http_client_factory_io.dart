import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

http.Client createSgtpHttpClient() {
  final ioHttpClient = HttpClient()
    ..badCertificateCallback = (_, __, ___) => true;
  return IOClient(ioHttpClient);
}

