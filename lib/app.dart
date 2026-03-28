import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:window_manager/window_manager.dart';

import 'core/window_size_service.dart';
import 'data/repositories/settings_repository.dart';
import 'presentation/blocs/setup/setup_bloc.dart';
import 'presentation/pages/home_screen.dart';
import 'presentation/pages/setup_page.dart';

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
    return MaterialApp(
      title: 'SGTP Chat',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1565C0), brightness: Brightness.light),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1565C0), brightness: Brightness.dark),
      ),
      themeMode: ThemeMode.system,
      initialRoute: '/',
      routes: {
        '/': (_) => const AppStartScreen(),
        '/setup': (_) => BlocProvider(
          create: (_) => SetupBloc(settings: SettingsRepository()),
          child: const SetupPage(),
        ),
      },
    );
  }
}
