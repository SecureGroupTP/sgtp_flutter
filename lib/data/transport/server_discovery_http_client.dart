export 'server_discovery_http_client_default.dart'
    if (dart.library.io) 'server_discovery_http_client_io.dart'
    if (dart.library.html) 'server_discovery_http_client_web.dart';
