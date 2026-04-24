import 'dart:convert';
import 'dart:typed_data';

import 'package:sgtp_flutter/features/notifications/domain/entities/notification_event.dart';

class ParsedPushMessage {
  const ParsedPushMessage({
    required this.accountId,
    required this.deviceId,
    required this.event,
  });

  final String? accountId;
  final String? deviceId;
  final NotificationEvent event;
}

class PushMessagePayloadParser {
  const PushMessagePayloadParser();

  ParsedPushMessage? parse(Map<String, String> data) {
    final eventType = _firstValue(data, const <String>[
      'pushType',
      'notificationKind',
      'kind',
      'eventType',
    ]);
    if (eventType == null) {
      return null;
    }

    final accountId = _firstValue(data, const <String>['accountId']);
    final deviceId = _firstValue(data, const <String>['deviceId']);
    final normalizedType = eventType.trim();

    if (_isMessageType(normalizedType)) {
      final eventId = _firstValue(data, const <String>['eventId', 'messageId']);
      final roomId = _firstValue(data, const <String>['roomId', 'threadId']);
      if (eventId == null || roomId == null) {
        return null;
      }
      return ParsedPushMessage(
        accountId: accountId,
        deviceId: deviceId,
        event: NotificationEvent.message(
          eventId: eventId,
          segmentId: _firstValue(data, const <String>['segmentId']) ?? roomId,
          accountId: accountId ?? '',
          threadId: roomId,
          senderId:
              _firstValue(data, const <String>[
                'senderId',
                'senderPublicKey',
                'senderPublicKeyHex',
              ]) ??
              '',
          senderName:
              _firstValue(data, const <String>['senderName', 'title']) ??
              'New message',
          senderAvatarBytes: _decodeAvatar(data),
          messageCount:
              _parsePositiveInt(
                _firstValue(data, const <String>['messageCount']),
              ) ??
              1,
        ),
      );
    }

    if (_isFriendRequestType(normalizedType)) {
      final eventId =
          _firstValue(data, const <String>['eventId', 'requestId']) ??
          _composeFallbackEventId(data);
      final peerId = _firstValue(data, const <String>[
        'peerId',
        'senderId',
        'senderPublicKey',
        'senderPublicKeyHex',
      ]);
      if (eventId == null || peerId == null) {
        return null;
      }
      return ParsedPushMessage(
        accountId: accountId,
        deviceId: deviceId,
        event: NotificationEvent.friendRequest(
          eventId: eventId,
          segmentId: _firstValue(data, const <String>['segmentId']) ?? peerId,
          accountId: accountId ?? '',
          peerId: peerId,
          displayName:
              _firstValue(data, const <String>[
                'displayName',
                'senderName',
                'title',
              ]) ??
              'New activity',
          senderAvatarBytes: _decodeAvatar(data),
        ),
      );
    }

    return null;
  }

  bool _isMessageType(String value) {
    return switch (value) {
      'mlsMessageReceived' || 'message' || 'message.received' => true,
      _ => false,
    };
  }

  bool _isFriendRequestType(String value) {
    return switch (value) {
      'friend.requestReceived' || 'friendRequest' || 'friend_request' => true,
      _ => false,
    };
  }

  String? _firstValue(Map<String, String> data, List<String> keys) {
    for (final key in keys) {
      final value = data[key]?.trim();
      if (value != null && value.isNotEmpty) {
        return value;
      }
    }
    return null;
  }

  int? _parsePositiveInt(String? raw) {
    final parsed = int.tryParse(raw ?? '');
    if (parsed == null || parsed <= 0) {
      return null;
    }
    return parsed;
  }

  Uint8List? _decodeAvatar(Map<String, String> data) {
    final raw = _firstValue(data, const <String>[
      'avatarBase64',
      'senderAvatarBase64',
    ]);
    if (raw == null) {
      return null;
    }
    try {
      return Uint8List.fromList(base64Decode(raw));
    } catch (_) {
      return null;
    }
  }

  String? _composeFallbackEventId(Map<String, String> data) {
    final peerId = _firstValue(data, const <String>[
      'peerId',
      'senderId',
      'senderPublicKey',
      'senderPublicKeyHex',
    ]);
    if (peerId == null) {
      return null;
    }
    return 'friend_request:$peerId';
  }
}
