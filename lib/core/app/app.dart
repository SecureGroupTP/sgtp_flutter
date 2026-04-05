import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:window_manager/window_manager.dart';

import 'package:sgtp_flutter/core/app_theme.dart';
import 'package:sgtp_flutter/core/window_size_service.dart';
import 'package:sgtp_flutter/features/messaging/application/services/chat_storage_gateway.dart';
import 'package:sgtp_flutter/features/messaging/data/repositories/chat_storage_gateway_impl.dart';
import 'package:sgtp_flutter/features/setup/application/services/setup_data_access.dart';
import 'package:sgtp_flutter/features/shell/presentation/pages/home_screen.dart';

bool get _isDesktop =>
    !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);

class SgtpApp extends StatefulWidget {
  const SgtpApp({super.key});

  @override
  State<SgtpApp> createState() => _SgtpAppState();
}

class _SgtpAppState extends State<SgtpApp> with WindowListener {
  @override
  void initState() {
    super.initState();
    if (_isDesktop) windowManager.addListener(this);
  }

  @override
  void dispose() {
    if (_isDesktop) windowManager.removeListener(this);
    super.dispose();
  }

  // Save size whenever the user finishes resizing
  @override
  void onWindowResized() => WindowSizeService.saveCurrentSize();

  // Also save on move (covers snap-to-half etc. that change effective size)
  @override
  void onWindowMoved() => WindowSizeService.saveCurrentSize();

  @override
  Widget build(BuildContext context) {
    return MultiRepositoryProvider(
      providers: [
        RepositoryProvider<SettingsRepository>(
          create: (_) => SettingsRepository(),
        ),
        RepositoryProvider<AppBackupRepository>(
          create: (_) => AppBackupRepository(),
        ),
        RepositoryProvider<ChatStorageGateway>(
          create: (_) => const DefaultChatStorageGateway(),
        ),
      ],
      child: MaterialApp(
        title: 'SGTP Chat',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.dark(),
        darkTheme: AppTheme.dark(),
        themeMode: ThemeMode.dark,
        initialRoute: '/',
        routes: {
          '/': (_) => const AppStartScreen(),
        },
      ),
    );
  }
}
