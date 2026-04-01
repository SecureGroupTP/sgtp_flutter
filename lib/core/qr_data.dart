import 'dart:convert';
import 'dart:typed_data';
import 'sgtp_transport.dart';

/// Data that can be encoded in QR code for sharing room/profile
class QrShareData {
  /// Type: 'room', 'profile', or 'node'
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

  /// Node id (for type='node')
  final String? nodeId;

  /// Node name (for type='node')
  final String? nodeName;

  /// Node host (for type='node')
  final String? nodeHost;

  /// Node chat port (for type='node')
  final int? nodeChatPort;

  /// Node voice port (for type='node')
  final int? nodeVoicePort;
  final String? nodeTransport;
  final bool? nodeUseTls;

  const QrShareData({
    required this.type,
    this.roomUUID,
    this.serverAddress,
    this.publicKeyHex,
    this.nickname,
    this.nodeId,
    this.nodeName,
    this.nodeHost,
    this.nodeChatPort,
    this.nodeVoicePort,
    this.nodeTransport,
    this.nodeUseTls,
    required this.timestamp,
  });

  /// Encode to JSON then base64
  String toBase64() {
    return base64.encode(_encodedBytes);
  }

  /// Encode to JSON then lowercase hex.
  String toHex() {
    final bytes = _encodedBytes;
    final buffer = StringBuffer();
    for (final byte in bytes) {
      buffer.write(byte.toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }

  Uint8List get _encodedBytes {
    final json = {
      'type': type,
      if (roomUUID != null) 'room': roomUUID,
      if (serverAddress != null) 'server': serverAddress,
      if (publicKeyHex != null) 'pubkey': publicKeyHex,
      if (nickname != null) 'nick': nickname,
      if (nodeId != null) 'nid': nodeId,
      if (nodeName != null) 'name': nodeName,
      if (nodeHost != null) 'host': nodeHost,
      if (nodeChatPort != null) 'chat': nodeChatPort,
      if (nodeVoicePort != null) 'voice': nodeVoicePort,
      if (nodeTransport != null) 'transport': nodeTransport,
      if (nodeUseTls != null) 'tls': nodeUseTls,
      'ts': timestamp,
    };
    final jsonStr = jsonEncode(json);
    return Uint8List.fromList(utf8.encode(jsonStr));
  }

  /// Decode from base64 to JSON
  static QrShareData? fromBase64(String encoded) {
    try {
      return _fromBytes(Uint8List.fromList(base64.decode(encoded.trim())));
    } catch (_) {
      return null;
    }
  }

  /// Decode from lowercase/uppercase hex to JSON.
  static QrShareData? fromHex(String encoded) {
    try {
      final normalized = encoded.trim().replaceAll(RegExp(r'\s+'), '');
      if (normalized.length.isOdd ||
          !RegExp(r'^[0-9a-fA-F]+$').hasMatch(normalized)) {
        return null;
      }
      final bytes = Uint8List.fromList(List.generate(
        normalized.length ~/ 2,
        (i) => int.parse(normalized.substring(i * 2, i * 2 + 2), radix: 16),
      ));
      return _fromBytes(bytes);
    } catch (_) {
      return null;
    }
  }

  /// Decode from either base64 or hex.
  static QrShareData? parse(String encoded) {
    return fromHex(encoded) ?? fromBase64(encoded);
  }

  static QrShareData? _fromBytes(Uint8List bytes) {
    final decoded = utf8.decode(bytes);
    final json = jsonDecode(decoded) as Map<String, dynamic>;

    return QrShareData(
      type: json['type'] as String? ?? 'room',
      roomUUID: json['room'] as String?,
      serverAddress: json['server'] as String?,
      publicKeyHex: json['pubkey'] as String?,
      nickname: json['nick'] as String?,
      nodeId: json['nid'] as String?,
      nodeName: json['name'] as String?,
      nodeHost: json['host'] as String?,
      nodeChatPort: (json['chat'] as num?)?.toInt(),
      nodeVoicePort: (json['voice'] as num?)?.toInt(),
      nodeTransport: (json['transport'] as String?)?.trim(),
      nodeUseTls: json['tls'] as bool?,
      // 'users' key is ignored for backward compatibility
      timestamp: json['ts'] as int? ?? DateTime.now().millisecondsSinceEpoch,
    );
  }

  SgtpTransportFamily? get nodeTransportFamily {
    final raw = (nodeTransport ?? '').trim();
    if (raw.isEmpty) return null;
    return SgtpTransportFamilyCodec.fromId(raw);
  }

  /// Generate QR content string
  String toQrContent() => toBase64();
}
