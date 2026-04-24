import 'package:sgtp_flutter/features/notifications/domain/repositories/push_device_registry.dart';
import 'package:sgtp_flutter/features/settings/application/services/settings_management_service.dart';

class SettingsPushDeviceRegistry implements PushDeviceRegistry {
  SettingsPushDeviceRegistry({
    required SettingsManagementService settingsManagementService,
  }) : _settingsManagementService = settingsManagementService;

  final SettingsManagementService _settingsManagementService;

  @override
  Future<String> loadDeviceId(String accountId) async {
    final snapshot = await _settingsManagementService.loadAccountSnapshot(
      accountId,
    );
    return snapshot.deviceId;
  }

  @override
  Future<String?> resolveAccountId({
    String? accountId,
    String? deviceId,
  }) async {
    final normalizedAccountId = accountId?.trim();
    if (normalizedAccountId != null && normalizedAccountId.isNotEmpty) {
      return normalizedAccountId;
    }
    final normalizedDeviceId = deviceId?.trim();
    if (normalizedDeviceId == null || normalizedDeviceId.isEmpty) {
      return null;
    }
    final registry = await _settingsManagementService.reloadRegistryState();
    for (final candidate in registry.accountIds) {
      final snapshot = await _settingsManagementService.loadAccountSnapshot(
        candidate,
      );
      if (snapshot.deviceId.trim() == normalizedDeviceId) {
        return candidate;
      }
    }
    return null;
  }
}
