import 'package:flutter_test/flutter_test.dart';
import 'package:sgtp_flutter/features/notifications/application/services/push_message_payload_parser.dart';
import 'package:sgtp_flutter/features/notifications/domain/entities/notification_kind.dart';

void main() {
  group('PushMessagePayloadParser', () {
    const parser = PushMessagePayloadParser();

    test('parses message payload with device resolution hints', () {
      final parsed = parser.parse(<String, String>{
        'eventType': 'mlsMessageReceived',
        'messageId': 'evt-1',
        'deviceId': 'device-1',
        'roomId': 'room-1',
        'senderId': 'peer-1',
        'senderName': 'Alice',
        'messageCount': '2',
      });

      expect(parsed, isNotNull);
      expect(parsed!.deviceId, 'device-1');
      expect(parsed.accountId, isNull);
      expect(parsed.event.kind, NotificationKind.message);
      expect(parsed.event.eventId, 'evt-1');
      expect(parsed.event.segmentId, 'room-1');
      expect(parsed.event.threadId, 'room-1');
      expect(parsed.event.senderId, 'peer-1');
      expect(parsed.event.senderName, 'Alice');
      expect(parsed.event.messageCount, 2);
    });

    test('parses friend request payload with explicit account id', () {
      final parsed = parser.parse(<String, String>{
        'eventType': 'friend.requestReceived',
        'eventId': 'evt-2',
        'accountId': 'acc-1',
        'peerId': 'peer-7',
        'displayName': 'Bob',
      });

      expect(parsed, isNotNull);
      expect(parsed!.accountId, 'acc-1');
      expect(parsed.deviceId, isNull);
      expect(parsed.event.kind, NotificationKind.friendRequest);
      expect(parsed.event.eventId, 'evt-2');
      expect(parsed.event.peerId, 'peer-7');
      expect(parsed.event.displayName, 'Bob');
      expect(parsed.event.segmentId, 'peer-7');
    });

    test('returns null for unsupported payload', () {
      final parsed = parser.parse(<String, String>{
        'eventType': 'profile.updated',
        'eventId': 'evt-3',
      });

      expect(parsed, isNull);
    });
  });
}
