import 'dart:io';
import 'dart:ui';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sgtp_flutter/core/di/injector.dart';
import 'package:sgtp_flutter/core/logging/log_setup.dart';
import 'package:sgtp_flutter/features/notifications/application/services/push_message_payload_parser.dart';
import 'package:sgtp_flutter/features/notifications/application/services/push_message_processor.dart';
import 'package:sgtp_flutter/features/notifications/data/services/message_notification_sink.dart';
import 'package:sgtp_flutter/features/notifications/data/services/settings_push_device_registry.dart';

Future<void> configurePushBackgroundHandling() async {
  if (kIsWeb || !(Platform.isAndroid || Platform.isIOS)) {
    return;
  }
  try {
    if (Firebase.apps.isEmpty) {
      await Firebase.initializeApp();
    }
    FirebaseMessaging.onBackgroundMessage(
      sgtpFirebaseMessagingBackgroundHandler,
    );
  } catch (_) {}
}

@pragma('vm:entry-point')
Future<void> sgtpFirebaseMessagingBackgroundHandler(
  RemoteMessage message,
) async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  try {
    if (!kIsWeb) {
      final dir = await getApplicationDocumentsDirectory();
      LogSetup.init('${dir.path}/sgtp_logs.jsonl');
    }
    if (Firebase.apps.isEmpty) {
      await Firebase.initializeApp();
    }
  } catch (e, st) {
    debugPrint('SGTP push background init failed: $e\n$st');
    return;
  }

  try {
    final dependencies = await AppInjector.build();
    final processor = PushMessageProcessor(
      payloadParser: const PushMessagePayloadParser(),
      deviceRegistry: SettingsPushDeviceRegistry(
        settingsManagementService: dependencies.settingsManagementService,
      ),
      notificationSink: MessageNotificationSink(
        messageNotificationService: dependencies.messageNotificationService,
      ),
    );
    final processed = await processor.process(
      message.data.map((key, value) => MapEntry(key, value?.toString() ?? '')),
    );
    if (!processed) {
      debugPrint(
        'SGTP push background message dropped: keys=${message.data.keys.toList()}',
      );
    }
  } catch (e, st) {
    debugPrint('SGTP push background handler failed: $e\n$st');
  }
}
