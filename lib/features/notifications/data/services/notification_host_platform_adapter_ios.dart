import 'package:sgtp_flutter/features/notifications/data/services/notification_host_platform_method_channel.dart';

class IosNotificationHostPlatformAdapter
    extends MethodChannelNotificationHostPlatformAdapter {
  IosNotificationHostPlatformAdapter()
      : super('com.example.sgtp_flutter/notification_host_ios');
}
