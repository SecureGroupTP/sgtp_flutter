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
                        NotificationHostService.ensureAppNotificationsChannel(this)
                        result.success("supported")
                    }
'''),
    );
  });

  test('Android manifest declares FCM default notification channel', () {
    final source = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync().replaceAll('\r\n', '\n');

    expect(
      source,
      contains(
        'android:name="com.google.firebase.messaging.default_notification_channel_id"',
      ),
    );
    expect(source, contains('android:value="sgtp_app_notifications"'));
  });
}
