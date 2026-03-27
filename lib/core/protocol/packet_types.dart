/// SGTP packet type constants
class PacketType {
  PacketType._();

  /// Intent / announcement frame (header only, payload_length=0)
  static const int intent = 0x0000;

  /// PING - initial handshake (client hello)
  static const int ping = 0x0001;

  /// PONG - handshake response
  static const int pong = 0x0002;

  /// INFO - peer list request/response
  static const int info = 0x0003;

  /// CHAT_REQUEST - request chat key from master
  static const int chatRequest = 0x0004;

  /// CHAT_KEY - encrypted chat key issued by master
  static const int chatKey = 0x0005;

  /// CHAT_KEY_ACK - acknowledgement of chat key receipt
  static const int chatKeyAck = 0x0006;

  /// MESSAGE - encrypted chat message
  static const int message = 0x0007;

  /// FIN - session termination
  static const int fin = 0x000F;

  /// KICK_REQUEST - request to kick unresponsive peer
  static const int kickRequest = 0x0010;

  /// KICKED - master announces kicked peer
  static const int kicked = 0x0011;

  /// MESSAGE_FAILED - master notifies of rejected message
  static const int messageFailed = 0x0008;

  /// MESSAGE_FAILED_ACK - sender acknowledges MESSAGE_FAILED
  static const int messageFailedAck = 0x0009;

  /// STATUS - status/error frame encrypted with shared key
  static const int status = 0x000A;

  /// HSIR - History Info Request (broadcast)
  static const int hsir = 0x000B;

  /// HSI - History Info response
  static const int hsi = 0x000C;

  /// HSR - History Request (unicast batch request)
  static const int hsr = 0x000D;

  /// HSRA - History Request Answer
  static const int hsra = 0x000E;
}
