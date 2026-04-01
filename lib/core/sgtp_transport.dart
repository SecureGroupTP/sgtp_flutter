enum SgtpTransportFamily {
  tcp,
  http,
  websocket,
}

extension SgtpTransportFamilyCodec on SgtpTransportFamily {
  String get id => switch (this) {
        SgtpTransportFamily.tcp => 'tcp',
        SgtpTransportFamily.http => 'http',
        SgtpTransportFamily.websocket => 'websocket',
      };

  static SgtpTransportFamily fromId(String? id) {
    return switch ((id ?? '').trim().toLowerCase()) {
      'http' => SgtpTransportFamily.http,
      'websocket' || 'ws' => SgtpTransportFamily.websocket,
      _ => SgtpTransportFamily.tcp,
    };
  }
}

