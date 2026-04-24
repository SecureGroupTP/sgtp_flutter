import 'package:flutter/services.dart';
import 'package:sgtp_flutter/features/notifications/domain/entities/notification_host_status.dart';
import 'package:sgtp_flutter/features/notifications/domain/repositories/notification_host_platform_adapter.dart';

abstract class MethodChannelNotificationHostPlatformAdapter
    implements NotificationHostPlatformAdapter {
  MethodChannelNotificationHostPlatformAdapter(String channelName)
      : _channel = MethodChannel(channelName);

  final MethodChannel _channel;

  @override
  Future<NotificationHostStatus> initialize() async {
    final raw = await _channel.invokeMethod<String>('initialize');
    return switch (raw) {
      'supported' => NotificationHostStatus.supported,
      'permissionDenied' => NotificationHostStatus.permissionDenied,
      _ => NotificationHostStatus.unsupported,
    };
  }

  @override
  Future<bool> isRunning() async =>
      (await _channel.invokeMethod<bool>('isRunning')) ?? false;

  @override
  Future<void> startForAccount(String accountId) async {
    await _channel.invokeMethod<void>('start', <String, Object?>{
      'accountId': accountId,
    });
  }

  @override
  Future<void> stop() async {
    await _channel.invokeMethod<void>('stop');
  }

  @override
  Future<void> stopForAccount(String accountId) async {
    await _channel.invokeMethod<void>('stopForAccount', <String, Object?>{
      'accountId': accountId,
    });
  }
}
