import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'package:sgtp_flutter/core/app_notifications/app_notification_models.dart';
import 'package:sgtp_flutter/core/app_notifications/linux_native_notifications_adapter.dart';

class IoLinuxNativeNotificationsAdapter
    implements LinuxNativeNotificationsAdapter {
  IoLinuxNativeNotificationsAdapter();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  final Map<String, int> _idsByHandle = <String, int>{};
  final Map<String, AppNotificationButtonCallback> _actionCallbacks =
      <String, AppNotificationButtonCallback>{};
  final Map<String, LinuxNotificationTapCallback> _tapCallbacks =
      <String, LinuxNotificationTapCallback>{};
  Future<bool>? _initialized;

  @override
  Future<bool> isSupported({bool requiresActions = false}) async {
    if (!Platform.isLinux) {
      return false;
    }
    final ready = await _ensureInitialized();
    if (!ready) {
      return false;
    }
    try {
      final linuxPlugin = _plugin
          .resolvePlatformSpecificImplementation<
              LinuxFlutterLocalNotificationsPlugin>();
      final capabilities = await linuxPlugin?.getCapabilities();
      if (capabilities == null) {
        return false;
      }
      return !requiresActions || capabilities.actions;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> show(LinuxNativeNotificationRequest request) async {
    final ready = await _ensureInitialized();
    if (!ready) {
      throw StateError('Linux notifications are not available.');
    }
    final intId = _toIntId(request.id);
    _idsByHandle[request.id] = intId;
    if (request.onTap != null) {
      _tapCallbacks[request.id] = request.onTap!;
    }
    for (var index = 0; index < request.actions.length; index++) {
      _actionCallbacks['${request.id}:$index'] = request.actions[index].onPressed;
    }

    final details = LinuxNotificationDetails(
      defaultActionName: request.onTap == null ? null : 'Open',
      actions: [
        for (var index = 0; index < request.actions.length; index++)
          LinuxNotificationAction(
            key: '${request.id}:$index',
            label: request.actions[index].label,
          ),
      ],
      timeout: request.duration == null
          ? const LinuxNotificationTimeout.systemDefault()
          : LinuxNotificationTimeout(request.duration!.inMilliseconds),
      icon: AssetsLinuxIcon('assets/app_icon.png'),
      urgency: LinuxNotificationUrgency.normal,
    );
    await _plugin.show(
      intId,
      request.title,
      request.body,
      NotificationDetails(linux: details),
      payload: request.id,
    );
  }

  @override
  Future<void> dismiss(String handleId) async {
    final intId = _idsByHandle.remove(handleId);
    _tapCallbacks.remove(handleId);
    _actionCallbacks.removeWhere((key, _) => key.startsWith('$handleId:'));
    if (intId != null) {
      await _plugin.cancel(intId);
    }
  }

  @override
  Future<void> dismissAll() async {
    _idsByHandle.clear();
    _tapCallbacks.clear();
    _actionCallbacks.clear();
    await _plugin.cancelAll();
  }

  Future<bool> _ensureInitialized() {
    return _initialized ??= _initialize();
  }

  Future<bool> _initialize() async {
    try {
      final ok = await _plugin.initialize(
        InitializationSettings(
          linux: LinuxInitializationSettings(
            defaultActionName: 'Open',
            defaultIcon: AssetsLinuxIcon('assets/app_icon.png'),
          ),
        ),
        onDidReceiveNotificationResponse: _handleResponse,
      );
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<void> _handleResponse(NotificationResponse response) async {
    final payload = response.payload;
    if (payload == null || payload.isEmpty) {
      return;
    }
    switch (response.notificationResponseType) {
      case NotificationResponseType.selectedNotification:
        final callback = _tapCallbacks[payload];
        if (callback != null) {
          await Future<void>.sync(callback);
        }
        break;
      case NotificationResponseType.selectedNotificationAction:
        final callback = _actionCallbacks[response.actionId];
        if (callback != null) {
          await Future<void>.sync(callback);
        }
        break;
    }
  }

  int _toIntId(String handleId) {
    final hash = handleId.hashCode & 0x7fffffff;
    return hash == 0 ? 1 : hash;
  }
}

LinuxNativeNotificationsAdapter createLinuxNativeNotificationsAdapterImpl() =>
    IoLinuxNativeNotificationsAdapter();
