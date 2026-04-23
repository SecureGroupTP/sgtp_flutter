import 'dart:typed_data';

import 'package:sgtp_flutter/core/app_notifications/app_notification_models.dart';
import 'package:sgtp_flutter/core/app_notifications/app_notifications_backend.dart';
import 'package:sgtp_flutter/core/app_notifications/app_notifications_backend_stub.dart'
    if (dart.library.io) 'package:sgtp_flutter/core/app_notifications/app_notifications_backend_io.dart';

class AppNotificationHandle {
  AppNotificationHandle._(this.id, this._owner);

  final String id;
  final AppNotifications _owner;

  Future<void> delete() => _owner.dismiss(id);

  Future<void> dismiss() => delete();
}

class AppNotificationBuilder {
  AppNotificationBuilder._(this._owner);

  final AppNotifications _owner;

  Uint8List? _imageBytes;
  String? _title;
  String? _subtitle;
  Duration _duration = const Duration(seconds: 5);
  final List<AppNotificationButton> _buttons = <AppNotificationButton>[];

  AppNotificationBuilder setImage(Uint8List? imageBytes) {
    _imageBytes = imageBytes;
    return this;
  }

  AppNotificationBuilder setTitle(String? title) {
    _title = _normalizeText(title);
    return this;
  }

  AppNotificationBuilder setSubtitle(String? subtitle) {
    _subtitle = _normalizeText(subtitle);
    return this;
  }

  AppNotificationBuilder setDuration(Duration duration) {
    _duration = duration;
    return this;
  }

  AppNotificationBuilder addButton({
    required String label,
    AppNotificationButtonColor color = AppNotificationButtonColor.defaultColor,
    required AppNotificationButtonCallback onPressed,
  }) {
    final normalizedLabel = _normalizeText(label);
    if (normalizedLabel == null) {
      throw ArgumentError.value(label, 'label', 'Button label cannot be empty.');
    }
    if (_buttons.length >= 2) {
      throw StateError('AppNotifications support at most 2 buttons.');
    }
    _buttons.add(
      AppNotificationButton(
        label: normalizedLabel,
        color: color,
        onPressed: onPressed,
      ),
    );
    return this;
  }

  Future<AppNotificationHandle> show() {
    return _owner.show(
      AppNotificationRequest(
        imageBytes: _imageBytes,
        title: _title,
        subtitle: _subtitle,
        buttons: List<AppNotificationButton>.unmodifiable(_buttons),
        duration: _duration,
      ),
    );
  }

  static String? _normalizeText(String? value) {
    final trimmed = value?.trim();
    if (trimmed == null || trimmed.isEmpty) {
      return null;
    }
    return trimmed;
  }
}

class AppNotifications {
  AppNotifications._(this._backend) {
    _backend.setEventListener(_handleBackendEvent);
  }

  static final AppNotifications instance =
      AppNotifications._(createAppNotificationsBackend());

  final AppNotificationsBackend _backend;
  int _counter = 0;
  final Map<String, List<AppNotificationButtonCallback>> _buttonCallbacks =
      <String, List<AppNotificationButtonCallback>>{};

  AppNotificationBuilder builder() => AppNotificationBuilder._(this);

  Future<AppNotificationHandle> show(AppNotificationRequest request) async {
    final id = _nextId();
    if (_backend.supports(request)) {
      if (request.buttons.isNotEmpty) {
        _buttonCallbacks[id] = request.buttons
            .map((button) => button.onPressed)
            .toList(growable: false);
      }
      try {
        await _backend.show(id, request);
      } catch (_) {
        _buttonCallbacks.remove(id);
        rethrow;
      }
    }
    return AppNotificationHandle._(id, this);
  }

  Future<void> dismiss(String id) async {
    _buttonCallbacks.remove(id);
    await _backend.dismiss(id);
  }

  Future<void> dismissAll() async {
    _buttonCallbacks.clear();
    await _backend.dismissAll();
  }

  String _nextId() {
    _counter += 1;
    return '${DateTime.now().microsecondsSinceEpoch}-${_counter.toRadixString(16)}';
  }

  Future<void> _handleBackendEvent(AppNotificationEvent event) async {
    switch (event.type) {
      case AppNotificationEventType.actionInvoked:
        final callbacks = _buttonCallbacks.remove(event.id);
        final index = event.buttonIndex;
        if (callbacks == null || index == null) {
          return;
        }
        if (index < 0 || index >= callbacks.length) {
          return;
        }
        await Future<void>.sync(callbacks[index]);
        break;
      case AppNotificationEventType.dismissed:
        _buttonCallbacks.remove(event.id);
        break;
    }
  }
}
