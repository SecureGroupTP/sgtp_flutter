import 'package:sgtp_flutter/features/notifications/data/services/notification_host_platform_method_channel.dart';

class AndroidNotificationHostPlatformAdapter
    extends MethodChannelNotificationHostPlatformAdapter {
  AndroidNotificationHostPlatformAdapter()
      : super('com.example.sgtp_flutter/notification_host_android');
}
