import 'package:sgtp_flutter/features/notifications/domain/repositories/notification_host_platform_adapter.dart';

import 'notification_host_platform_adapter_stub.dart'
    if (dart.library.io) 'notification_host_platform_adapter_io.dart'
    if (dart.library.html) 'notification_host_platform_adapter_web.dart';

NotificationHostPlatformAdapter createNotificationHostPlatformAdapter() =>
    createNotificationHostPlatformAdapterImpl();
