import 'package:flutter_test/flutter_test.dart';
import 'package:sgtp_flutter/core/app_notifications/app_notification_models.dart';
import 'package:sgtp_flutter/features/notifications/application/services/notification_dispatcher.dart';
import 'package:sgtp_flutter/features/notifications/application/services/notification_projection_service.dart';
import 'package:sgtp_flutter/features/notifications/domain/entities/notification_account_context.dart';
import 'package:sgtp_flutter/features/notifications/domain/entities/notification_action.dart';
import 'package:sgtp_flutter/features/notifications/domain/entities/notification_event.dart';
import 'package:sgtp_flutter/features/notifications/domain/entities/notification_inbox_record.dart';
import 'package:sgtp_flutter/features/notifications/domain/entities/notification_projection.dart';
import 'package:sgtp_flutter/features/notifications/domain/repositories/notification_account_context_resolver.dart';
import 'package:sgtp_flutter/features/notifications/domain/repositories/notification_inbox_store.dart';
import 'package:sgtp_flutter/features/notifications/domain/repositories/notification_presenter.dart';

void main() {
  test('friend request projection keeps action buttons', () async {
    final projection = NotificationProjectionService().project(
      NotificationEvent.friendRequest(
        eventId: 'evt-1',
        segmentId: 'seg-1',
        accountId: 'acc-1',
        peerId: 'peer-1',
        displayName: 'Alice',
        actions: <NotificationAction>[
          NotificationAction(
            label: 'Accept',
            onInvoked: () async {},
          ),
          NotificationAction(
            label: 'Decline',
            color: AppNotificationButtonColor.red,
            onInvoked: () async {},
          ),
        ],
      ),
      const NotificationAccountContext(
        accountId: 'acc-1',
        genericOnly: false,
      ),
    );

    expect(projection.actions, hasLength(2));
    expect(projection.actions.first.label, 'Accept');
    expect(projection.actions.last.color, AppNotificationButtonColor.red);
  });

  test('dispatcher passes actions to presenter', () async {
    final presenter = _ActionCapturingPresenter();
    final dispatcher = NotificationDispatcher(
      projectionService: const NotificationProjectionService(),
      inboxStore: _MemoryStore(),
      presenter: presenter,
      accountContextResolver: _StaticResolver(),
    );

    await dispatcher.dispatch(
      NotificationEvent.friendRequest(
        eventId: 'evt-1',
        segmentId: 'seg-1',
        accountId: 'acc-1',
        peerId: 'peer-1',
        displayName: 'Alice',
        actions: <NotificationAction>[
          NotificationAction(
            label: 'Accept',
            onInvoked: () async {},
          ),
        ],
      ),
    );

    expect(presenter.lastProjection, isNotNull);
    expect(presenter.lastProjection!.actions, hasLength(1));
    expect(presenter.lastProjection!.actions.first.label, 'Accept');
  });
}

class _StaticResolver implements NotificationAccountContextResolver {
  @override
  Future<NotificationAccountContext> resolve(String accountId) async =>
      NotificationAccountContext(accountId: accountId, genericOnly: false);
}

class _MemoryStore implements NotificationInboxStore {
  final List<NotificationInboxRecord> _records = <NotificationInboxRecord>[];

  @override
  Future<void> closeAccount(String accountId) async {}

  @override
  Future<NotificationInboxRecord?> findByDedupKey(
    String accountId,
    String dedupKey,
  ) async {
    for (final record in _records) {
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
    for (final record in _records.reversed) {
      if (record.accountId == accountId && record.collapseKey == collapseKey) {
        return record;
      }
    }
    return null;
  }

  @override
  Future<void> save(NotificationInboxRecord record) async {
    _records.add(record);
  }
}

class _ActionCapturingPresenter implements NotificationPresenter {
  NotificationProjection? lastProjection;

  @override
  Future<void> dismiss(String handleId) async {}

  @override
  Future<String> show(NotificationProjection projection) async {
    lastProjection = projection;
    return 'handle-1';
  }
}
