import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:window_manager/window_manager.dart';

import 'package:sgtp_flutter/core/app_theme.dart';
import 'package:sgtp_flutter/core/app/app_shell.dart';
import 'package:sgtp_flutter/core/di/injector.dart';
import 'package:sgtp_flutter/core/network/sgtp_connection_service.dart';
import 'package:sgtp_flutter/core/window_size_service.dart';
import 'package:sgtp_flutter/features/messaging/domain/repositories/chat_storage_gateway.dart';
import 'package:sgtp_flutter/features/messaging/domain/repositories/direct_room_gateway.dart';
import 'package:sgtp_flutter/features/messaging/domain/repositories/i_sgtp_session.dart';
import 'package:sgtp_flutter/features/messaging/domain/repositories/key_package_publisher.dart';
import 'package:sgtp_flutter/features/contacts/application/services/contacts_directory_service.dart';
import 'package:sgtp_flutter/features/settings/application/services/settings_management_service.dart';
import 'package:sgtp_flutter/features/shell/application/services/app_startup_service.dart';
import 'package:sgtp_flutter/features/shell/application/services/home_persistence_service.dart';
import 'package:sgtp_flutter/features/shell/application/services/home_userdir_support_service.dart';

bool get _isDesktop =>
    !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);

class SgtpApp extends StatefulWidget {
  const SgtpApp({
    super.key,
    required this.dependencies,
  });

  final AppDependencies dependencies;

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
        RepositoryProvider<AppDependencies>(
          create: (_) => widget.dependencies,
        ),
RepositoryProvider<ChatStorageGateway>(
          create: (_) => widget.dependencies.chatStorageGateway,
        ),
        RepositoryProvider<AppStartupService>(
          create: (_) => widget.dependencies.appStartupService,
        ),
        RepositoryProvider<ContactsDirectoryService>(
          create: (_) => widget.dependencies.contactsDirectoryService,
        ),
        RepositoryProvider<SettingsManagementService>(
          create: (_) => widget.dependencies.settingsManagementService,
        ),
        RepositoryProvider<HomePersistenceService>(
          create: (_) => widget.dependencies.homePersistenceService,
        ),
        RepositoryProvider<HomeUserDirSupportService>(
          create: (_) => widget.dependencies.homeUserDirSupportService,
        ),
        RepositoryProvider<SgtpConnectionService>(
          create: (_) => widget.dependencies.sgtpConnectionService,
        ),
        RepositoryProvider<DirectRoomGateway>(
          create: (_) => widget.dependencies.directRoomGateway,
        ),
        RepositoryProvider<KeyPackagePublisher>(
          create: (_) => widget.dependencies.keyPackagePublisher,
        ),
        RepositoryProvider<SgtpSessionFactory>(
          create: (_) => widget.dependencies.sgtpSessionFactory,
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
          '/': (_) => const AppShell(),
        },
      ),
    );
  }
}
