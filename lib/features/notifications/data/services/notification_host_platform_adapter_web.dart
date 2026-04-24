// ignore_for_file: avoid_web_libraries_in_flutter

import 'dart:html' as html;

import 'package:sgtp_flutter/features/notifications/domain/entities/notification_host_status.dart';
import 'package:sgtp_flutter/features/notifications/domain/repositories/notification_host_platform_adapter.dart';

class WebNotificationHostPlatformAdapter
    implements NotificationHostPlatformAdapter {
  bool _initialized = false;

  @override
  Future<NotificationHostStatus> initialize() async {
    if (_initialized) {
      return NotificationHostStatus.supported;
    }
    if (!html.Notification.supported) {
      return NotificationHostStatus.unsupported;
    }
    try {
      await html.window.navigator.serviceWorker?.register(
        'notification_host_sw.js',
      );
    } catch (_) {}
    final permission = await html.Notification.requestPermission();
    _initialized = permission == 'granted';
    if (_initialized) {
      return NotificationHostStatus.supported;
    }
    return NotificationHostStatus.permissionDenied;
  }

  @override
  Future<bool> isRunning() async => _initialized;

  @override
  Future<void> startForAccount(String accountId) async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> stopForAccount(String accountId) async {}
}

NotificationHostPlatformAdapter createNotificationHostPlatformAdapterImpl() =>
    WebNotificationHostPlatformAdapter();
