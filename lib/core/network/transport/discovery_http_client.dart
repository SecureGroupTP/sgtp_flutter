export 'discovery_http_client_default.dart'
    if (dart.library.io) 'discovery_http_client_io.dart'
    if (dart.library.html) 'discovery_http_client_web.dart';
