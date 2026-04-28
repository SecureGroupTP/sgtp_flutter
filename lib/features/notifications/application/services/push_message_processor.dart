import 'package:sgtp_flutter/core/app_log.dart';
import 'package:sgtp_flutter/features/notifications/application/services/push_message_payload_parser.dart';
import 'package:sgtp_flutter/features/notifications/domain/entities/notification_kind.dart';
import 'package:sgtp_flutter/features/notifications/domain/repositories/push_device_registry.dart';
import 'package:sgtp_flutter/features/notifications/domain/repositories/push_notification_sink.dart';

final _log = AppLog('PushMessageProcessor');

class PushMessageProcessor {
  PushMessageProcessor({
    required PushMessagePayloadParser payloadParser,
    required PushDeviceRegistry deviceRegistry,
    required PushNotificationSink notificationSink,
  }) : _payloadParser = payloadParser,
       _deviceRegistry = deviceRegistry,
       _notificationSink = notificationSink;

  final PushMessagePayloadParser _payloadParser;
  final PushDeviceRegistry _deviceRegistry;
  final PushNotificationSink _notificationSink;

  Future<bool> process(Map<String, String> data) async {
    final parsed = _payloadParser.parse(data);
    if (parsed == null) {
      _log.warning(
        'Push payload dropped before parse. Keys: {keys}',
        parameters: {'keys': data.keys.join(',')},
      );
      return false;
    }
    final accountId = await _deviceRegistry.resolveAccountId(
      accountId: parsed.accountId,
      deviceId: parsed.deviceId,
    );
    final normalizedAccountId = accountId?.trim();
    if (normalizedAccountId == null || normalizedAccountId.isEmpty) {
      _log.warning(
        'Push payload dropped: account not resolved. Event: {eventType}, device={device}',
        parameters: {
          'eventType': parsed.event.kind.name,
          'device': parsed.deviceId ?? '',
        },
      );
      return false;
    }

    final event = parsed.event.withAccountId(normalizedAccountId);
    _log.info(
      'Push payload accepted. Kind: {kind}, event={eventId}, account={account}',
      parameters: {
        'kind': event.kind.name,
        'eventId': event.eventId,
        'account': normalizedAccountId,
      },
    );
    switch (event.kind) {
      case NotificationKind.message:
        await _notificationSink.showMessage(event);
        return true;
      case NotificationKind.friendRequest:
        await _notificationSink.showFriendRequest(event);
        return true;
      case NotificationKind.service:
        return false;
    }
  }
}
