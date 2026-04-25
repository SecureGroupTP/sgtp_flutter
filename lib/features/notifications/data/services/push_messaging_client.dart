import 'dart:async';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:sgtp_flutter/features/notifications/domain/repositories/push_messaging_client.dart';

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
    return messaging.onTokenRefresh;
  }

  @override
  Future<String?> getToken() async {
    final messaging = _messaging;
    if (!_available || messaging == null) {
      return null;
    }
    return messaging.getToken();
  }

  @override
  Future<void> initialize() async {
    if (!_supportsCurrentPlatform()) {
      _available = false;
      return;
    }
    try {
      if (Firebase.apps.isEmpty) {
        await Firebase.initializeApp();
      }
      _messaging = FirebaseMessaging.instance;
      _available = true;
    } catch (_) {
      _messaging = null;
      _available = false;
    }
  }

  @override
  Future<bool> requestPermission() async {
    if (!_available) {
      return false;
    }
    if (!kIsWeb && Platform.isAndroid) {
      return true;
    }
    final messaging = _messaging;
    if (messaging == null) {
      return false;
    }
    final settings = await messaging.requestPermission(
      alert: true,
      badge: true,
      sound: true,
      provisional: false,
    );
    return settings.authorizationStatus == AuthorizationStatus.authorized ||
        settings.authorizationStatus == AuthorizationStatus.provisional;
  }

  bool _supportsCurrentPlatform() {
    if (kIsWeb) {
      return false;
    }
    return Platform.isAndroid || Platform.isIOS;
  }
}
