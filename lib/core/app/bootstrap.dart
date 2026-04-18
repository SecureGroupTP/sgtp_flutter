import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sgtp_chat_core/sgtp_chat_core.dart';
import 'package:window_manager/window_manager.dart';

import 'package:sgtp_flutter/core/di/injector.dart';
import 'package:sgtp_flutter/core/interaction_prefs.dart';
import 'package:sgtp_flutter/core/logging/log_setup.dart';
import 'package:sgtp_flutter/core/notification_service.dart';
import 'package:sgtp_flutter/core/window_size_service.dart';

Future<AppDependencies> bootstrapApp() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  if (!kIsWeb) {
    final dir = await getApplicationDocumentsDirectory();
    LogSetup.init('${dir.path}/sgtp_logs.jsonl');
  }

  await InteractionPrefs.load();

  if (!kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux)) {
    await windowManager.ensureInitialized();
    await WindowSizeService.restoreSize();
  }

  await NotificationService.init();

  await MessengerMls.ensureInitialized();

  return AppInjector.build();
}
