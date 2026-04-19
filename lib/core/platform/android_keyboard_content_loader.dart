import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class AndroidKeyboardContentLoader {
  static const MethodChannel _channel = MethodChannel(
    'com.example.sgtp_flutter/keyboard_content',
  );

  static Future<Uint8List?> loadBytes(String uri) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return null;
    }
    final bytes = await _channel.invokeMethod<Uint8List>(
      'readContentUriBytes',
      <String, Object?>{'uri': uri},
    );
    if (bytes == null || bytes.isEmpty) {
      return null;
    }
    return bytes;
  }
}
