import 'package:sgtp_flutter/features/notifications/domain/entities/notification_host_status.dart';
import 'package:sgtp_flutter/features/notifications/domain/repositories/notification_host_platform_adapter.dart';

class NotificationHostService {
  NotificationHostService({
    required NotificationHostPlatformAdapter platformAdapter,
  }) : _platformAdapter = platformAdapter;

  final NotificationHostPlatformAdapter _platformAdapter;
  Future<NotificationHostStatus>? _initializeFuture;
  String? _activeAccountId;
  NotificationHostStatus? _status;

  Future<NotificationHostStatus> ensureInitialized() async {
    final status = await (_initializeFuture ??= _platformAdapter.initialize());
    _status = status;
    return status;
  }

  Future<void> start() async {
    final activeAccountId = _activeAccountId;
    if (activeAccountId == null || activeAccountId.isEmpty) {
      return;
    }
    if (await ensureInitialized() != NotificationHostStatus.supported) {
      return;
    }
    await _platformAdapter.startForAccount(activeAccountId);
  }

  Future<void> activateAccount(String accountId) async {
    final normalized = accountId.trim();
    if (normalized.isEmpty || normalized == _activeAccountId) {
      return;
    }
    final previous = _activeAccountId;
    _activeAccountId = normalized;
    if (await ensureInitialized() != NotificationHostStatus.supported) {
      return;
    }
    if (previous != null && previous.isNotEmpty) {
      await _platformAdapter.stopForAccount(previous);
    }
    await _platformAdapter.startForAccount(normalized);
  }

  Future<void> deactivateAccount(String accountId) async {
    final normalized = accountId.trim();
    if (normalized.isEmpty || normalized != _activeAccountId) {
      return;
    }
    if (await ensureInitialized() != NotificationHostStatus.supported) {
      _activeAccountId = null;
      return;
    }
    await _platformAdapter.stopForAccount(normalized);
    _activeAccountId = null;
  }

  Future<void> stop() async {
    if (await ensureInitialized() != NotificationHostStatus.supported) {
      _activeAccountId = null;
      return;
    }
    await _platformAdapter.stop();
    _activeAccountId = null;
  }

  Future<bool> isRunning() async {
    if ((_status ?? await ensureInitialized()) !=
        NotificationHostStatus.supported) {
      return false;
    }
    return _platformAdapter.isRunning();
  }
}
