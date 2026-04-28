import 'package:flutter/material.dart';

import 'package:sgtp_flutter/core/app/bootstrap_gate.dart';
import 'package:sgtp_flutter/features/notifications/data/services/push_background_handler.dart'
    as push_background_handler;

typedef EnsureFlutterBinding = void Function();
typedef ConfigurePushBackgroundHandling = Future<void> Function();
typedef RunFlutterApp = void Function();

Future<void> runSgtpApp({
  EnsureFlutterBinding ensureBinding = WidgetsFlutterBinding.ensureInitialized,
  ConfigurePushBackgroundHandling configurePushBackgroundHandling =
      push_background_handler.configurePushBackgroundHandling,
  RunFlutterApp runApp = _runDefaultApp,
}) async {
  ensureBinding();
  await configurePushBackgroundHandling();
  runApp();
}

void _runDefaultApp() => runApp(const BootstrapGate());
