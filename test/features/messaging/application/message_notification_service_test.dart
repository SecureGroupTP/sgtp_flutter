import 'package:flutter_test/flutter_test.dart';
import 'package:sgtp_flutter/core/app/notification_interaction_service.dart';
import 'package:sgtp_flutter/features/messaging/application/services/message_notification_service.dart';
import 'package:sgtp_flutter/features/notifications/application/services/notification_dispatcher.dart';
import 'package:sgtp_flutter/features/notifications/application/services/notification_projection_service.dart';
import 'package:sgtp_flutter/features/notifications/domain/entities/notification_account_context.dart';
import 'package:sgtp_flutter/features/notifications/domain/entities/notification_inbox_record.dart';
import 'package:sgtp_flutter/features/notifications/domain/entities/notification_projection.dart';
import 'package:sgtp_flutter/features/notifications/domain/repositories/notification_account_context_resolver.dart';
import 'package:sgtp_flutter/features/notifications/domain/repositories/notification_inbox_store.dart';
import 'package:sgtp_flutter/features/notifications/domain/repositories/notification_presenter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('MessageNotificationService', () {
    test('message notifications include fallback avatar and body', () async {
      final presenter = _CapturingPresenter();
      final service = MessageNotificationService(
        notificationDispatcher: NotificationDispatcher(
          projectionService: const NotificationProjectionService(),
          inboxStore: _InMemoryInboxStore(),
          presenter: presenter,
          accountContextResolver: _StaticContextResolver(),
        ),
        interactionService: NotificationInteractionService(),
      );

      await service.showMessageEvent(
        accountId: 'acc-1',
        eventId: 'evt-1',
        segmentId: 'seg-1',
        roomId: 'room-1',
        senderId: 'peer-1',
        senderName: 'Alice',
        body: 'hello there',
      );

      expect(presenter.shown, hasLength(1));
      final payload = presenter.shown.single.safePayload;
      expect(payload.title, 'Alice');
      expect(payload.body, 'hello there');
      expect(payload.avatarBytes, isNotNull);
      expect(payload.avatarBytes, isNotEmpty);
    });
  });
}

class _StaticContextResolver implements NotificationAccountContextResolver {
  @override
  Future<NotificationAccountContext> resolve(String accountId) async =>
      NotificationAccountContext(accountId: accountId, genericOnly: false);
}

class _InMemoryInboxStore implements NotificationInboxStore {
  final List<NotificationInboxRecord> records = <NotificationInboxRecord>[];

  @override
  Future<void> closeAccount(String accountId) async {}

  @override
  Future<NotificationInboxRecord?> findByDedupKey(
    String accountId,
    String dedupKey,
  ) async {
    for (final record in records) {
      if (record.accountId == accountId && record.dedupKey == dedupKey) {
        return record;
      }
    }
    return null;
  }

  @override
  Future<NotificationInboxRecord?> findLatestByCollapseKey(
    String accountId,
    String collapseKey,
  ) async {
    NotificationInboxRecord? latest;
    for (final record in records) {
      if (record.accountId != accountId || record.collapseKey != collapseKey) {
        continue;
      }
      if (latest == null || record.shownAtMs > latest.shownAtMs) {
        latest = record;
      }
    }
    return latest;
  }

  @override
  Future<void> save(NotificationInboxRecord record) async {
    records.add(record);
  }
}

class _CapturingPresenter implements NotificationPresenter {
  final List<NotificationProjection> shown = <NotificationProjection>[];

  @override
  Future<void> dismiss(String handleId) async {}

  @override
  Future<String> show(NotificationProjection projection) async {
    shown.add(projection);
    return 'shown-${shown.length}';
  }
}
