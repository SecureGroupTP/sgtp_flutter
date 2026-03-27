import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'data/repositories/settings_repository.dart';
import 'presentation/blocs/setup/setup_bloc.dart';
import 'presentation/pages/setup_page.dart';

class SgtpApp extends StatelessWidget {
  const SgtpApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SGTP Chat',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1565C0),
          brightness: Brightness.light,
        ),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1565C0),
          brightness: Brightness.dark,
        ),
      ),
      themeMode: ThemeMode.system,
      home: BlocProvider(
        create: (_) => SetupBloc(settings: SettingsRepository()),
        child: const SetupPage(),
      ),
    );
  }
}
