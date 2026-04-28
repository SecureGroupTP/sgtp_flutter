import 'package:flutter/foundation.dart';

class PushPlatform {
  const PushPlatform._();

  static const int unsupported = 0;
  static const int android = 2;

  static int currentCode() {
    if (kIsWeb) {
      return unsupported;
    }
    if (defaultTargetPlatform == TargetPlatform.android) {
      return android;
    }
    return unsupported;
  }
}
