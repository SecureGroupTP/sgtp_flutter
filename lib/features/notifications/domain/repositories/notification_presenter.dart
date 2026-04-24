import 'package:sgtp_flutter/features/notifications/domain/entities/notification_projection.dart';

abstract class NotificationPresenter {
  Future<String> show(NotificationProjection projection);

  Future<void> dismiss(String handleId);
}
