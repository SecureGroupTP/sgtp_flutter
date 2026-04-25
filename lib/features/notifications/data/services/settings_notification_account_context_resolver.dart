import 'package:sgtp_flutter/features/notifications/domain/entities/notification_account_context.dart';
import 'package:sgtp_flutter/features/notifications/domain/repositories/notification_account_context_resolver.dart';
import 'package:sgtp_flutter/features/settings/application/services/settings_management_service.dart';

class SettingsNotificationAccountContextResolver
    implements NotificationAccountContextResolver {
  SettingsNotificationAccountContextResolver({
    required SettingsManagementService settingsManagementService,
  }) : _settingsManagementService = settingsManagementService;

  final SettingsManagementService _settingsManagementService;

  @override
  Future<NotificationAccountContext> resolve(String accountId) async {
    final state = await _settingsManagementService.loadLocalEncryptionState();
    return NotificationAccountContext(
      accountId: accountId,
      genericOnly: state.enabled,
    );
  }
}
