import 'dart:async';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:sgtp_flutter/core/app_log.dart';
import 'package:sgtp_flutter/features/notifications/domain/repositories/push_messaging_client.dart';

final _log = AppLog('FirebasePushMessagingClient');

class FirebasePushMessagingClient implements PushMessagingClient {
  FirebasePushMessagingClient();

  FirebaseMessaging? _messaging;
  bool _available = false;

  @override
  Stream<Map<String, String>> get onForegroundMessage {
    if (!_available) {
      return const Stream<Map<String, String>>.empty();
    }
    return FirebaseMessaging.onMessage.map((message) {
      _log.info(
        'Firebase foreground message received. Id: {id}, keys={keys}',
        parameters: {
          'id': message.messageId ?? '',
          'keys': message.data.keys.join(','),
        },
      );
      return message.data.map(
        (key, value) => MapEntry(key, value?.toString() ?? ''),
      );
    });
  }

  @override
  Stream<String> get onTokenRefresh {
    final messaging = _messaging;
    if (!_available || messaging == null) {
      return const Stream<String>.empty();
    }
    return messaging.onTokenRefresh.map((token) {
      _log.info(
        'Firebase token refreshed. Length: {length}',
        parameters: {'length': token.length},
      );
      return token;
    });
  }

  @override
  Future<String?> getToken() async {
    final messaging = _messaging;
    if (!_available || messaging == null) {
      return null;
    }
    try {
      return await messaging.getToken();
    } catch (e, st) {
      _log.warning(
        'Firebase getToken failed: {error}',
        parameters: {'error': e},
        error: e,
        stackTrace: st,
      );
      return null;
    }
  }

  @override
  Future<void> initialize() async {
    if (!_supportsCurrentPlatform()) {
      _log.info('Firebase messaging skipped: unsupported platform');
      _available = false;
      return;
    }
    try {
      if (Firebase.apps.isEmpty) {
        await Firebase.initializeApp();
      }
      _messaging = FirebaseMessaging.instance;
      _available = true;
      _log.info('Firebase messaging initialized');
    } catch (e, st) {
      _log.warning(
        'Firebase messaging initialization failed: {error}',
        parameters: {'error': e},
        error: e,
        stackTrace: st,
      );
      _messaging = null;
      _available = false;
    }
  }

  @override
  Future<bool> requestPermission() async {
    if (!_available) {
      return false;
    }
    final messaging = _messaging;
    if (messaging == null) {
      return false;
    }
    try {
      final settings = await messaging.requestPermission(
        alert: true,
        badge: true,
        sound: true,
        provisional: false,
      );
      _log.info(
        'Firebase notification permission status: {status}',
        parameters: {'status': settings.authorizationStatus.name},
      );
      return settings.authorizationStatus == AuthorizationStatus.authorized ||
          settings.authorizationStatus == AuthorizationStatus.provisional;
    } catch (e, st) {
      _log.warning(
        'Firebase notification permission request failed: {error}',
        parameters: {'error': e},
        error: e,
        stackTrace: st,
      );
      return false;
    }
  }

  bool _supportsCurrentPlatform() {
    if (kIsWeb) {
      return false;
    }
    return Platform.isAndroid || Platform.isIOS;
  }
}
