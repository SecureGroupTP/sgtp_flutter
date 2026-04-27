import 'package:flutter/foundation.dart';
import 'package:sgtp_flutter/core/app_notifications/app_notifications.dart';
import 'package:sgtp_flutter/core/app_notifications/app_notification_models.dart';
import 'package:sgtp_flutter/core/app_notifications/custom_app_notifications_controller.dart';
import 'package:sgtp_flutter/core/app_notifications/linux_native_notifications_adapter.dart';
import 'package:sgtp_flutter/features/notifications/domain/entities/notification_projection.dart';
import 'package:sgtp_flutter/features/notifications/domain/entities/notification_kind.dart';
import 'package:sgtp_flutter/features/notifications/domain/entities/linux_notification_settings.dart';
import 'package:sgtp_flutter/features/notifications/domain/repositories/notification_presenter.dart';
import 'package:sgtp_flutter/features/settings/application/services/settings_management_service.dart';

class AppNotificationPresenter implements NotificationPresenter {
  AppNotificationPresenter({
    required SettingsManagementService settingsManagementService,
    required CustomAppNotificationsController customController,
    required LinuxNativeNotificationsAdapter linuxNativeAdapter,
  }) : _settingsManagementService = settingsManagementService,
       _customController = customController,
       _linuxNativeAdapter = linuxNativeAdapter;

  final SettingsManagementService _settingsManagementService;
  final CustomAppNotificationsController _customController;
  final LinuxNativeNotificationsAdapter _linuxNativeAdapter;
  final Map<String, _PresentedNotificationMode> _presentationModes =
      <String, _PresentedNotificationMode>{};

  @override
  Future<void> dismiss(String handleId) async {
    final mode = _presentationModes.remove(handleId);
    switch (mode) {
      case _PresentedNotificationMode.customLinux:
        await _customController.dismiss(handleId);
        return;
      case _PresentedNotificationMode.nativeLinux:
        await _linuxNativeAdapter.dismiss(handleId);
        return;
      case _PresentedNotificationMode.legacy:
      case null:
        await AppNotifications.instance.dismiss(handleId);
        return;
    }
  }

  @override
  Future<String> show(NotificationProjection projection) async {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.linux) {
      return _showLinux(projection);
    }
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
    _presentationModes[handle.id] = _PresentedNotificationMode.legacy;
    return handle.id;
  }

  Future<String> _showLinux(NotificationProjection projection) async {
    final settings = await _settingsManagementService
        .loadLinuxNotificationSettings();
    await _customController.configure(settings);
    final handleId =
        '${DateTime.now().microsecondsSinceEpoch}-${projection.dedupKey.hashCode.abs()}';
    if (!settings.enabled) {
      _presentationModes[handleId] = _PresentedNotificationMode.customLinux;
      return handleId;
    }

    final body = _resolveBody(projection: projection, settings: settings);
    final canUseNative =
        settings.mode == LinuxNotificationMode.native &&
        await _linuxNativeAdapter.isSupported(
          requiresActions: projection.actions.isNotEmpty,
        );
    if (canUseNative) {
      try {
        await _linuxNativeAdapter.show(
          LinuxNativeNotificationRequest(
            id: handleId,
            title: projection.safePayload.title,
            body: body,
            duration: settings.customDuration,
            onTap: projection.onTap,
            actions: projection.actions
                .map(
                  (action) => AppNotificationButton(
                    label: action.label,
                    color: action.color,
                    onPressed: action.onInvoked,
                  ),
                )
                .toList(growable: false),
          ),
        );
        _presentationModes[handleId] = _PresentedNotificationMode.nativeLinux;
        return handleId;
      } catch (_) {}
    }

    final title = projection.safePayload.title.trim();
    await _customController.show(
      CustomAppNotificationEntry(
        id: handleId,
        title: title,
        body: body,
        initials: _initialsFor(title),
        createdAt: DateTime.now(),
        duration: settings.customDuration,
        position: settings.position,
        showAvatar: settings.showAvatars,
        avatarBytes: projection.safePayload.avatarBytes,
        onTap: projection.onTap,
        actions: projection.actions
            .map(
              (action) => AppNotificationButton(
                label: action.label,
                color: action.color,
                onPressed: action.onInvoked,
              ),
            )
            .toList(growable: false),
      ),
    );
    _presentationModes[handleId] = _PresentedNotificationMode.customLinux;
    return handleId;
  }

  String? _resolveBody({
    required NotificationProjection projection,
    required LinuxNotificationSettings settings,
  }) {
    if (projection.kind == NotificationKind.message &&
        !settings.showMessagePreview) {
      return 'New message';
    }
    return projection.safePayload.body;
  }

  String _initialsFor(String title) {
    final parts = title
        .trim()
        .split(RegExp(r'\s+'))
        .where((part) => part.isNotEmpty)
        .toList(growable: false);
    if (parts.isEmpty) {
      return 'SG';
    }
    final letters = parts.take(2).map((part) => part[0].toUpperCase()).join();
    return letters.isEmpty ? 'SG' : letters;
  }
}

enum _PresentedNotificationMode { legacy, nativeLinux, customLinux }
