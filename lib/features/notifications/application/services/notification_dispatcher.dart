import 'package:sgtp_flutter/features/notifications/application/services/notification_projection_service.dart';
import 'package:sgtp_flutter/features/notifications/domain/entities/notification_event.dart';
import 'package:sgtp_flutter/features/notifications/domain/entities/notification_inbox_record.dart';
import 'package:sgtp_flutter/features/notifications/domain/repositories/notification_account_context_resolver.dart';
import 'package:sgtp_flutter/features/notifications/domain/repositories/notification_inbox_store.dart';
import 'package:sgtp_flutter/features/notifications/domain/repositories/notification_presenter.dart';

class NotificationDispatcher {
  NotificationDispatcher({
    required NotificationProjectionService projectionService,
    required NotificationInboxStore inboxStore,
    required NotificationPresenter presenter,
    required NotificationAccountContextResolver accountContextResolver,
  })  : _projectionService = projectionService,
        _inboxStore = inboxStore,
        _presenter = presenter,
        _accountContextResolver = accountContextResolver;

  final NotificationProjectionService _projectionService;
  final NotificationInboxStore _inboxStore;
  final NotificationPresenter _presenter;
  final NotificationAccountContextResolver _accountContextResolver;
  final Map<String, String> _activeHandlesByCollapseKey = <String, String>{};

  Future<void> dispatch(
    NotificationEvent event, {
    bool suppressPresentation = false,
  }) async {
    final accountContext = await _accountContextResolver.resolve(event.accountId);
    final projection = _projectionService.project(event, accountContext);
    if (!projection.shouldShow) {
      return;
    }
    final existing = await _inboxStore.findByDedupKey(
      event.accountId,
      projection.dedupKey,
    );
    if (existing != null) {
      return;
    }

    await _inboxStore.save(
      NotificationInboxRecord(
        eventId: event.eventId,
        segmentId: event.segmentId,
        accountId: event.accountId,
        threadId: event.threadId,
        peerId: event.peerId,
        kind: projection.kind,
        shownAtMs: DateTime.now().millisecondsSinceEpoch,
        dedupKey: projection.dedupKey,
        collapseKey: projection.collapseKey,
        safePayload: projection.safePayload,
      ),
    );

    if (suppressPresentation) {
      return;
    }

    final previousHandleId = _activeHandlesByCollapseKey[projection.collapseKey];
    if (previousHandleId != null) {
      await _presenter.dismiss(previousHandleId);
    }
    final nextHandleId = await _presenter.show(projection);
    _activeHandlesByCollapseKey[projection.collapseKey] = nextHandleId;
  }

  Future<void> dismissCollapseKey(String collapseKey) async {
    final handleId = _activeHandlesByCollapseKey.remove(collapseKey);
    if (handleId == null) {
      return;
    }
    await _presenter.dismiss(handleId);
  }

  Future<void> dismissAllActive() async {
    final handleIds = _activeHandlesByCollapseKey.values.toList(growable: false);
    _activeHandlesByCollapseKey.clear();
    for (final handleId in handleIds) {
      await _presenter.dismiss(handleId);
    }
  }
}
