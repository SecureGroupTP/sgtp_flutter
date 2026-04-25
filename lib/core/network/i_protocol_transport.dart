import 'dart:typed_data';

/// Low-level bidirectional bytes transport.
///
/// Implementations: HTTP (POST per message), WebSocket, TCP.
/// The two data interaction methods are [send] and [registerPacketCallback].
abstract class IProtocolTransport {
  bool get isConnected;

  /// Stream of all incoming packet bytes.
  /// Equivalent to [registerPacketCallback] but as a broadcast stream.
  Stream<Uint8List> get inbound;

  Future<void> connect();
  Future<void> close();

  /// Send raw bytes to the remote end.
  Future<void> send(Uint8List bytes);

  /// Register a callback that is invoked for every received packet.
  /// Only one callback can be registered at a time — subsequent calls replace
  /// the previous registration.
  void registerPacketCallback(void Function(Uint8List bytes) callback);
}
