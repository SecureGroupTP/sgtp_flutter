import 'dart:convert';
import 'dart:typed_data';

/// Data that can be encoded in QR code for sharing room/profile
class QrShareData {
  /// Type: 'room' or 'profile'
  final String type;
  
  /// Room UUID (for type='room')
  final String? roomUUID;
  
  /// Server address (for type='room' or 'profile')
  final String? serverAddress;
  
  /// User's public key hex (for type='profile')
  final String? publicKeyHex;
  
  /// User's nickname (for type='profile')
  final String? nickname;
  
  /// Timestamp when created
  final int timestamp;

  const QrShareData({
    required this.type,
    this.roomUUID,
    this.serverAddress,
    this.publicKeyHex,
    this.nickname,
    required this.timestamp,
  });

  /// Encode to JSON then base64
  String toBase64() {
    final json = {
      'type': type,
      if (roomUUID != null) 'room': roomUUID,
      if (serverAddress != null) 'server': serverAddress,
      if (publicKeyHex != null) 'pubkey': publicKeyHex,
      if (nickname != null) 'nick': nickname,
      'ts': timestamp,
    };
    final jsonStr = jsonEncode(json);
    return base64.encode(utf8.encode(jsonStr));
  }

  /// Decode from base64 to JSON
  static QrShareData? fromBase64(String encoded) {
    try {
      final decoded = utf8.decode(base64.decode(encoded));
      final json = jsonDecode(decoded) as Map<String, dynamic>;
      
      return QrShareData(
        type: json['type'] as String? ?? 'room',
        roomUUID: json['room'] as String?,
        serverAddress: json['server'] as String?,
        publicKeyHex: json['pubkey'] as String?,
        nickname: json['nick'] as String?,
        timestamp: json['ts'] as int? ?? DateTime.now().millisecondsSinceEpoch,
      );
    } catch (e) {
      print('❌ [QR] Failed to decode: $e');
      return null;
    }
  }

  /// Generate QR content string
  String toQrContent() => toBase64();
}
