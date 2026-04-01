import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../../core/sgtp_server_options.dart';

class SgtpServerDiscovery {
  static Future<SgtpServerOptions> discover(
    String host,
    int discoveryPort, {
    Duration timeout = const Duration(seconds: 2),
  }) async {
    final socket = await Socket.connect(host, discoveryPort)
        .timeout(timeout, onTimeout: () {
      throw TimeoutException('Discovery timeout');
    });

    final buf = BytesBuilder(copy: false);
    late final StreamSubscription sub;
    final completer = Completer<Uint8List>();
    sub = socket.listen(
      (data) {
        buf.add(data);
        final bytes = buf.toBytes();
        if (bytes.length >= SgtpServerOptions.wireBytesLength &&
            !completer.isCompleted) {
          completer.complete(Uint8List.sublistView(
              bytes, 0, SgtpServerOptions.wireBytesLength));
        }
      },
      onError: (e) {
        if (!completer.isCompleted) completer.completeError(e);
      },
      onDone: () {
        if (!completer.isCompleted) {
          completer.completeError(StateError(
              'Discovery connection closed before ${SgtpServerOptions.wireBytesLength} bytes'));
        }
      },
      cancelOnError: true,
    );

    try {
      final bytes = await completer.future.timeout(timeout, onTimeout: () {
        throw TimeoutException('Discovery timeout');
      });
      return SgtpServerOptions.fromBytes(bytes);
    } finally {
      await sub.cancel();
      socket.destroy();
    }
  }
}

