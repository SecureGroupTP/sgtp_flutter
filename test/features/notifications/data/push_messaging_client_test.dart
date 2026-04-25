import 'package:flutter_test/flutter_test.dart';
import 'package:sgtp_flutter/features/notifications/data/services/push_messaging_client.dart';

void main() {
  group('FirebasePushMessagingClient', () {
    test('can be constructed on unsupported desktop platforms', () {
      expect(FirebasePushMessagingClient.new, returnsNormally);
    });
  });
}
