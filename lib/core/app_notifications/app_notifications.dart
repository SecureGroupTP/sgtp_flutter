import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

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

class AppNotificationRequest {
  const AppNotificationRequest({
    this.imageBytes,
    this.title,
    this.subtitle,
    required this.duration,
  });

  final Uint8List? imageBytes;
  final String? title;
  final String? subtitle;
  final Duration duration;
}

class AppNotifications {
  AppNotifications._();

  static final AppNotifications instance = AppNotifications._();

  static const MethodChannel _channel = MethodChannel(
    'com.example.sgtp_flutter/app_notifications',
  );

  int _counter = 0;

  AppNotificationBuilder builder() => AppNotificationBuilder._(this);

  Future<AppNotificationHandle> show(AppNotificationRequest request) async {
    final id = _nextId();
    if (!_supportsCustomNotifications || !_hasVisiblePayload(request)) {
      return AppNotificationHandle._(id, this);
    }
    await _channel.invokeMethod<void>('showNotification', <String, Object?>{
      'id': id,
      'title': request.title,
      'subtitle': request.subtitle,
      'durationMs': request.duration.inMilliseconds,
      'imageBytes': request.imageBytes,
    });
    return AppNotificationHandle._(id, this);
  }

  Future<void> dismiss(String id) async {
    if (!_supportsCustomNotifications) {
      return;
    }
    await _channel.invokeMethod<void>('dismissNotification', <String, Object?>{
      'id': id,
    });
  }

  Future<void> dismissAll() async {
    if (!_supportsCustomNotifications) {
      return;
    }
    await _channel.invokeMethod<void>('dismissAllNotifications');
  }

  bool get _supportsCustomNotifications =>
      !kIsWeb && Platform.isWindows;

  bool _hasVisiblePayload(AppNotificationRequest request) {
    return (request.title != null && request.title!.isNotEmpty) ||
        (request.subtitle != null && request.subtitle!.isNotEmpty) ||
        (request.imageBytes != null && request.imageBytes!.isNotEmpty);
  }

  String _nextId() {
    _counter += 1;
    return '${DateTime.now().microsecondsSinceEpoch}-${_counter.toRadixString(16)}';
  }
}
