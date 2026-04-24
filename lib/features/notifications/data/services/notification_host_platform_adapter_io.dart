import 'dart:io';

import 'package:sgtp_flutter/features/notifications/domain/repositories/notification_host_platform_adapter.dart';

import 'notification_host_platform_adapter_android.dart';
import 'notification_host_platform_adapter_ios.dart';
import 'notification_host_platform_adapter_stub.dart' as stub_adapter;
import 'notification_host_platform_adapter_windows.dart';

NotificationHostPlatformAdapter createNotificationHostPlatformAdapterImpl() {
  if (Platform.isAndroid) {
    return AndroidNotificationHostPlatformAdapter();
  }
  if (Platform.isIOS) {
    return IosNotificationHostPlatformAdapter();
  }
  if (Platform.isWindows) {
    return WindowsNotificationHostPlatformAdapter();
  }
  return stub_adapter.createNotificationHostPlatformAdapterImpl();
}
