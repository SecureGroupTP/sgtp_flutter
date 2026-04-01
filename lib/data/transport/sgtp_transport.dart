import 'dart:typed_data';

abstract class SgtpTransport {
  Stream<Uint8List> get inbound;
  bool get isConnected;

  Future<void> connect();
  Future<void> send(Uint8List bytes);
  Future<void> close();
}

