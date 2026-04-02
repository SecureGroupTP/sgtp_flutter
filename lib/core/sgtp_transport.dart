import 'package:flutter/foundation.dart' show kIsWeb;

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

  /// Whether this transport can be used on the current platform.
  /// TCP requires dart:io and is unavailable on Flutter Web.
  bool get isAvailableOnPlatform =>
      this != SgtpTransportFamily.tcp || !kIsWeb;

  static SgtpTransportFamily fromId(String? id) {
    return switch ((id ?? '').trim().toLowerCase()) {
      'http' => SgtpTransportFamily.http,
      'websocket' || 'ws' => SgtpTransportFamily.websocket,
      _ => SgtpTransportFamily.tcp,
    };
  }

  /// Returns the transport family to use, falling back to WebSocket on web
  /// if TCP was selected (since dart:io is unavailable there).
  static SgtpTransportFamily resolve(SgtpTransportFamily preferred) {
    if (kIsWeb && preferred == SgtpTransportFamily.tcp) {
      return SgtpTransportFamily.websocket;
    }
    return preferred;
  }
}

/// All transport families that are selectable on the current platform.
List<SgtpTransportFamily> get availableTransportFamilies =>
    SgtpTransportFamily.values
        .where((f) => f.isAvailableOnPlatform)
        .toList();
