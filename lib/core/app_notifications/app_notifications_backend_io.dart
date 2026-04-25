import 'dart:io';

import 'package:sgtp_flutter/core/app_notifications/app_notifications_backend.dart';
import 'package:sgtp_flutter/core/app_notifications/app_notifications_backend_mobile.dart';
import 'package:sgtp_flutter/core/app_notifications/app_notifications_backend_stub.dart';
import 'package:sgtp_flutter/core/app_notifications/app_notifications_backend_windows.dart';

AppNotificationsBackend createAppNotificationsBackend() {
  if (Platform.isWindows) {
    return WindowsAppNotificationsBackend();
  }
  if (Platform.isAndroid || Platform.isIOS) {
    return MobileAppNotificationsBackend();
  }
  return const UnsupportedAppNotificationsBackend();
}
