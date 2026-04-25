import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

http.Client createSgtpHttpClient({
  required String host,
  required int port,
  required bool useTls,
  String? fakeSni,
}) {
  final ioHttpClient = HttpClient();
  final tlsServerName = (fakeSni ?? '').trim();
  if (useTls &&
      tlsServerName.isNotEmpty &&
      tlsServerName.toLowerCase() != host.toLowerCase()) {
    ioHttpClient.connectionFactory =
        (Uri uri, String? proxyHost, int? proxyPort) async {
      final connectHost = (proxyHost ?? uri.host).trim();
      final connectPort = proxyPort ?? uri.port;
      final socketFuture = () async {
        // Preserve default proxy behavior. Custom TLS override only applies
        // when connecting directly to origin.
        if ((proxyHost ?? '').trim().isNotEmpty) {
          return Socket.connect(connectHost, connectPort);
        }
        if (uri.scheme.toLowerCase() != 'https') {
          return Socket.connect(connectHost, connectPort);
        }
        final raw = await Socket.connect(connectHost, connectPort);
        return SecureSocket.secure(
          raw,
          host: tlsServerName,
        );
      }();
      return ConnectionTask.fromSocket<Socket>(
        socketFuture,
        () async {
          try {
            (await socketFuture).destroy();
          } catch (_) {}
        },
      );
    };
  }
  return IOClient(ioHttpClient);
}
