import 'dart:typed_data';

/// Protocol constants for SGTP
class SgtpConstants {
  SgtpConstants._();

  static const String clientHello = 'Client Hello';

  static final Uint8List broadcastUUID = Uint8List(16);

  static const int version = 0x0001;

  // Packet types
  static const int pktIntent = 0x0000;
  static const int pktPing = 0x0001;
  static const int pktPong = 0x0002;
  static const int pktInfo = 0x0003;
  static const int pktChatRequest = 0x0004;
  static const int pktChatKey = 0x0005;
  static const int pktChatKeyAck = 0x0006;
  static const int pktMessage = 0x0007;
  static const int pktFin = 0x000F;
  static const int pktKickRequest = 0x0010;
  static const int pktKicked = 0x0011;
  static const int pktMessageFailed = 0x0008;
  static const int pktMessageFailedAck = 0x0009;
  static const int pktStatus = 0x000A;
  static const int pktHsir = 0x000B;
  static const int pktHsi = 0x000C;
  static const int pktHsr = 0x000D;
  static const int pktHsra = 0x000E;

  /// Chat key rotation interval in seconds (§1: CK_ROTATION_INTERVAL = 180s)
  static const int ckRotationInterval = 180;

  /// Timestamp validity window in milliseconds (§1: TIMESTAMP_WINDOW = 30 000ms)
  static const int timestampWindow = 30000;

  /// Maximum payload size (§1: MAX_PAYLOAD_LENGTH = 16 MiB)
  static const int maxPayloadSize = 16 * 1024 * 1024;

  /// Delay before sending INFO request after first PING/PONG, in milliseconds
  /// (§1: INFO_DELAY = 1s)
  static const int infoDelayMs = 1000;

  /// PING timeout in seconds (§1: PING_TIMEOUT = 30s)
  static const int pingTimeout = 30;

  /// Message failed max retries (§1: MESSAGE_FAILED_RETRIES = 3)
  static const int messageFailedRetries = 3;

  /// Header size in bytes
  static const int headerSize = 64;

  /// Signature size in bytes
  static const int signatureSize = 64;

  /// PING/PONG payload length: 32 (x25519) + 32 (ed25519) + 12 ("Client Hello") = 76
  static const int pingPayloadLength = 76;

  /// Minimum PING/PONG payload: 32 + 32 = 64
  static const int pingPayloadMinLength = 64;

  /// CHAT_KEY payload length: 8 (epoch) + 48 (ciphertext) = 56
  static const int chatKeyPayloadLength = 56;

  /// FIN payload length: 8 (nonce) + 16 (poly1305 tag) = 24
  static const int finPayloadLength = 24;

  /// Chunk size for large media files (8 MiB raw)
  static const int mediaChunkSize = 8 * 1024 * 1024;
}
