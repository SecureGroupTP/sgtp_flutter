import 'package:sgtp_flutter/features/notifications/domain/entities/notification_account_context.dart';

abstract class NotificationAccountContextResolver {
  Future<NotificationAccountContext> resolve(String accountId);
}
