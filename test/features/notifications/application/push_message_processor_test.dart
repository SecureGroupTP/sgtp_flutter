import 'package:flutter_test/flutter_test.dart';
import 'package:sgtp_flutter/features/notifications/application/services/push_message_payload_parser.dart';
import 'package:sgtp_flutter/features/notifications/application/services/push_message_processor.dart';
import 'package:sgtp_flutter/features/notifications/domain/entities/notification_event.dart';
import 'package:sgtp_flutter/features/notifications/domain/repositories/push_device_registry.dart';
import 'package:sgtp_flutter/features/notifications/domain/repositories/push_notification_sink.dart';

void main() {
  group('PushMessageProcessor', () {
    test('resolves account by device id and forwards message event', () async {
      final sink = _FakeSink();
      final processor = PushMessageProcessor(
        payloadParser: const PushMessagePayloadParser(),
        deviceRegistry: _FakeRegistry(resolvedAccountId: 'acc-1'),
        notificationSink: sink,
      );

      final processed = await processor.process(<String, String>{
        'eventType': 'mlsMessageReceived',
        'messageId': 'evt-1',
        'deviceId': 'device-1',
        'roomId': 'room-1',
        'senderId': 'peer-1',
        'senderName': 'Alice',
      });

      expect(processed, isTrue);
      expect(sink.messageEvents, hasLength(1));
      expect(sink.messageEvents.single.accountId, 'acc-1');
      expect(sink.messageEvents.single.eventId, 'evt-1');
    });

    test('drops payload when account cannot be resolved', () async {
      final sink = _FakeSink();
      final processor = PushMessageProcessor(
        payloadParser: const PushMessagePayloadParser(),
        deviceRegistry: _FakeRegistry(resolvedAccountId: null),
        notificationSink: sink,
      );

      final processed = await processor.process(<String, String>{
        'eventType': 'mlsMessageReceived',
        'messageId': 'evt-1',
        'deviceId': 'device-1',
        'roomId': 'room-1',
      });

      expect(processed, isFalse);
      expect(sink.messageEvents, isEmpty);
      expect(sink.friendRequestEvents, isEmpty);
    });
  });
}

class _FakeRegistry implements PushDeviceRegistry {
  _FakeRegistry({required this.resolvedAccountId});

  final String? resolvedAccountId;

  @override
  Future<String> loadDeviceId(String accountId) {
    throw UnimplementedError();
  }

  @override
  Future<String?> resolveAccountId({
    String? accountId,
    String? deviceId,
  }) async {
    return accountId ?? resolvedAccountId;
  }
}

class _FakeSink implements PushNotificationSink {
  final List<NotificationEvent> messageEvents = <NotificationEvent>[];
  final List<NotificationEvent> friendRequestEvents = <NotificationEvent>[];

  @override
  Future<void> showFriendRequest(NotificationEvent event) async {
    friendRequestEvents.add(event);
  }

  @override
  Future<void> showMessage(NotificationEvent event) async {
    messageEvents.add(event);
  }
}
