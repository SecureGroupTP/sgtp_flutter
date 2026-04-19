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

  Future<AppNotificationHandle> show() {
    return _owner.show(
      AppNotificationRequest(
        imageBytes: _imageBytes,
        title: _title,
        subtitle: _subtitle,
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
  AppNotifications._(this._backend);

  static final AppNotifications instance =
      AppNotifications._(createAppNotificationsBackend());

  final AppNotificationsBackend _backend;
  int _counter = 0;

  AppNotificationBuilder builder() => AppNotificationBuilder._(this);

  Future<AppNotificationHandle> show(AppNotificationRequest request) async {
    final id = _nextId();
    if (_backend.supports(request)) {
      await _backend.show(id, request);
    }
    return AppNotificationHandle._(id, this);
  }

  Future<void> dismiss(String id) => _backend.dismiss(id);

  Future<void> dismissAll() => _backend.dismissAll();

  String _nextId() {
    _counter += 1;
    return '${DateTime.now().microsecondsSinceEpoch}-${_counter.toRadixString(16)}';
  }
}
