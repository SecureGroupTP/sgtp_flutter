import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sgtp_flutter/features/notifications/application/services/notification_dispatcher.dart';
import 'package:sgtp_flutter/features/notifications/application/services/notification_projection_service.dart';
import 'package:sgtp_flutter/features/notifications/domain/entities/notification_account_context.dart';
import 'package:sgtp_flutter/features/notifications/domain/entities/notification_event.dart';
import 'package:sgtp_flutter/features/notifications/domain/entities/notification_inbox_record.dart';
import 'package:sgtp_flutter/features/notifications/domain/entities/notification_projection.dart';
import 'package:sgtp_flutter/features/notifications/domain/entities/notification_safe_payload.dart';
import 'package:sgtp_flutter/features/notifications/domain/repositories/notification_account_context_resolver.dart';
import 'package:sgtp_flutter/features/notifications/domain/repositories/notification_inbox_store.dart';
import 'package:sgtp_flutter/features/notifications/domain/repositories/notification_presenter.dart';

void main() {
  group('NotificationDispatcher', () {
    test('deduplicates repeated event ids', () async {
      final presenter = _FakePresenter();
      final store = _InMemoryInboxStore();
      final dispatcher = NotificationDispatcher(
        projectionService: NotificationProjectionService(),
        inboxStore: store,
        presenter: presenter,
        accountContextResolver: _StaticContextResolver(),
      );

      final event = NotificationEvent.message(
        eventId: 'evt-1',
        segmentId: 'seg-1',
        accountId: 'acc-1',
        threadId: 'room-1',
        senderId: 'peer-1',
        senderName: 'Alice',
        messageCount: 1,
      );

      await dispatcher.dispatch(event);
      await dispatcher.dispatch(event);

      expect(presenter.shown.length, 1);
      expect(store.records.length, 1);
    });

    test('collapses active notification by collapse key', () async {
      final presenter = _FakePresenter();
      final store = _InMemoryInboxStore();
      final dispatcher = NotificationDispatcher(
        projectionService: NotificationProjectionService(),
        inboxStore: store,
        presenter: presenter,
        accountContextResolver: _StaticContextResolver(),
      );

      await dispatcher.dispatch(
        NotificationEvent.message(
          eventId: 'evt-1',
          segmentId: 'seg-1',
          accountId: 'acc-1',
          threadId: 'room-1',
          senderId: 'peer-1',
          senderName: 'Alice',
          messageCount: 1,
        ),
      );
      await dispatcher.dispatch(
        NotificationEvent.message(
          eventId: 'evt-2',
          segmentId: 'seg-2',
          accountId: 'acc-1',
          threadId: 'room-1',
          senderId: 'peer-1',
          senderName: 'Alice',
          messageCount: 2,
        ),
      );

      expect(presenter.shown.length, 2);
      expect(presenter.dismissed, <String>['shown-1']);
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

class _FakePresenter implements NotificationPresenter {
  final List<NotificationSafePayload> shown = <NotificationSafePayload>[];
  final List<String> dismissed = <String>[];
  int _nextId = 0;

  @override
  Future<void> dismiss(String handleId) async {
    dismissed.add(handleId);
  }

  @override
  Future<String> show(NotificationProjection projection) async {
    shown.add(projection.safePayload);
    _nextId += 1;
    return 'shown-$_nextId';
  }
}
