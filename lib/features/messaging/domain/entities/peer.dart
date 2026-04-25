import 'dart:typed_data';
import 'package:equatable/equatable.dart';

/// Information about a connected peer.
class PeerInfo extends Equatable {
  /// Hex-encoded peer UUID
  final String uuid;

  /// Raw 16-byte UUID
  final Uint8List uuidBytes;

  /// Ed25519 long-term public key (32 bytes)
  final Uint8List ed25519PubKey;

  /// Symmetric key derived from X25519 (32 bytes), computed after handshake.
  final Uint8List sharedKey;

  /// Peer protocol version as received in PING/PONG.
  final int protocolVersion;

  /// Whether the handshake (PING/PONG exchange) is complete
  final bool handshakeComplete;

  const PeerInfo({
    required this.uuid,
    required this.uuidBytes,
    required this.ed25519PubKey,
    required this.sharedKey,
    required this.protocolVersion,
    required this.handshakeComplete,
  });

  PeerInfo copyWith({
    String? uuid,
    Uint8List? uuidBytes,
    Uint8List? ed25519PubKey,
    Uint8List? sharedKey,
    int? protocolVersion,
    bool? handshakeComplete,
  }) {
    return PeerInfo(
      uuid: uuid ?? this.uuid,
      uuidBytes: uuidBytes ?? this.uuidBytes,
      ed25519PubKey: ed25519PubKey ?? this.ed25519PubKey,
      sharedKey: sharedKey ?? this.sharedKey,
      protocolVersion: protocolVersion ?? this.protocolVersion,
      handshakeComplete: handshakeComplete ?? this.handshakeComplete,
    );
  }

  @override
  List<Object?> get props =>
      [uuid, uuidBytes, ed25519PubKey, sharedKey, protocolVersion, handshakeComplete];
}
