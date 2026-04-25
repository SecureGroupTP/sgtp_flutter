import 'package:sgtp_flutter/core/app_notifications/linux_native_notifications_adapter.dart';

class StubLinuxNativeNotificationsAdapter
    implements LinuxNativeNotificationsAdapter {
  @override
  Future<void> dismiss(String handleId) async {}

  @override
  Future<void> dismissAll() async {}

  @override
  Future<bool> isSupported({bool requiresActions = false}) async => false;

  @override
  Future<void> show(LinuxNativeNotificationRequest request) async {
    throw StateError('Linux native notifications are not supported here.');
  }
}

LinuxNativeNotificationsAdapter createLinuxNativeNotificationsAdapterImpl() =>
    StubLinuxNativeNotificationsAdapter();
