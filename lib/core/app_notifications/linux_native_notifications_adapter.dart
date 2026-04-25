import 'package:sgtp_flutter/core/app_notifications/app_notification_models.dart';

import 'linux_native_notifications_adapter_stub.dart'
    if (dart.library.io) 'linux_native_notifications_adapter_io.dart';

typedef LinuxNotificationTapCallback = Future<void> Function();

class LinuxNativeNotificationRequest {
  const LinuxNativeNotificationRequest({
    required this.id,
    required this.title,
    this.body,
    this.onTap,
    this.actions = const <AppNotificationButton>[],
    this.duration,
  });

  final String id;
  final String title;
  final String? body;
  final LinuxNotificationTapCallback? onTap;
  final List<AppNotificationButton> actions;
  final Duration? duration;
}

abstract class LinuxNativeNotificationsAdapter {
  Future<bool> isSupported({bool requiresActions = false});

  Future<void> show(LinuxNativeNotificationRequest request);

  Future<void> dismiss(String handleId);

  Future<void> dismissAll();
}

LinuxNativeNotificationsAdapter createLinuxNativeNotificationsAdapter() =>
    createLinuxNativeNotificationsAdapterImpl();
