import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android notification host channel reports host support', () {
    final source = File(
      'android/app/src/main/kotlin/com/example/sgtp_flutter/MainActivity.kt',
    ).readAsStringSync().replaceAll('\r\n', '\n');

    expect(
      source,
      contains('''
                    "initialize" -> {
                        NotificationHostService.ensureChannel(this)
                        result.success("supported")
                    }
'''),
    );
  });
}
