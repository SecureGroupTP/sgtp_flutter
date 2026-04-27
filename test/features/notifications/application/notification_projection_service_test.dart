import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sgtp_flutter/features/notifications/application/services/notification_projection_service.dart';
import 'package:sgtp_flutter/features/notifications/domain/entities/notification_account_context.dart';
import 'package:sgtp_flutter/features/notifications/domain/entities/notification_event.dart';
import 'package:sgtp_flutter/features/notifications/domain/entities/notification_kind.dart';

void main() {
  group('NotificationProjectionService', () {
    final service = NotificationProjectionService();

    test('builds message notification with preview body', () {
      final projection = service.project(
        NotificationEvent.message(
          eventId: 'evt-1',
          segmentId: 'seg-1',
          accountId: 'acc-1',
          threadId: 'room-1',
          senderId: 'peer-1',
          senderName: 'Alice',
          senderAvatarBytes: Uint8List.fromList(<int>[1, 2, 3]),
          body: 'hello there',
          messageCount: 2,
        ),
        const NotificationAccountContext(
          accountId: 'acc-1',
          genericOnly: false,
        ),
      );

      expect(projection.shouldShow, isTrue);
      expect(projection.kind, NotificationKind.message);
      expect(projection.safePayload.title, 'Alice');
      expect(projection.safePayload.subtitle, '2 new messages');
      expect(projection.safePayload.body, 'hello there');
      expect(projection.safePayload.avatarBytes, isNotNull);
      expect(projection.safePayload.title, isNot(contains('hello')));
    });

    test('builds generic message notification for protected account', () {
      final projection = service.project(
        NotificationEvent.message(
          eventId: 'evt-2',
          segmentId: 'seg-2',
          accountId: 'acc-1',
          threadId: 'room-1',
          senderId: 'peer-1',
          senderName: 'Alice',
          messageCount: 1,
        ),
        const NotificationAccountContext(accountId: 'acc-1', genericOnly: true),
      );

      expect(projection.shouldShow, isTrue);
      expect(projection.safePayload.title, 'New message');
      expect(projection.safePayload.subtitle, isNull);
      expect(projection.safePayload.body, isNull);
      expect(projection.safePayload.avatarBytes, isNull);
    });

    test('builds metadata-only friend request notification', () {
      final projection = service.project(
        NotificationEvent.friendRequest(
          eventId: 'evt-3',
          segmentId: 'seg-3',
          accountId: 'acc-1',
          peerId: 'peer-9',
          displayName: 'Bob',
        ),
        const NotificationAccountContext(
          accountId: 'acc-1',
          genericOnly: false,
        ),
      );

      expect(projection.shouldShow, isTrue);
      expect(projection.kind, NotificationKind.friendRequest);
      expect(projection.safePayload.title, 'Bob');
      expect(projection.safePayload.subtitle, 'Sent you a friend request');
      expect(projection.safePayload.body, 'Sent you a friend request');
    });
  });
}
