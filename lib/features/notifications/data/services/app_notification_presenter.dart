import 'package:sgtp_flutter/core/app_notifications/app_notifications.dart';
import 'package:sgtp_flutter/features/notifications/domain/entities/notification_projection.dart';
import 'package:sgtp_flutter/features/notifications/domain/repositories/notification_presenter.dart';

class AppNotificationPresenter implements NotificationPresenter {
  @override
  Future<void> dismiss(String handleId) async {
    await AppNotifications.instance.dismiss(handleId);
  }

  @override
  Future<String> show(NotificationProjection projection) async {
    final builder = AppNotifications.instance
        .builder()
        .setImage(projection.safePayload.avatarBytes)
        .setTitle(projection.safePayload.title)
        .setSubtitle(projection.safePayload.subtitle)
        .setDesktopDuration(const Duration(seconds: 6));
    for (final action in projection.actions) {
      builder.addButton(
        label: action.label,
        color: action.color,
        onPressed: action.onInvoked,
      );
    }
    final handle = await builder.show();
    return handle.id;
  }
}
