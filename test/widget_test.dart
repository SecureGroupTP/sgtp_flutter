import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:sgtp_flutter/core/app/app.dart';
import 'package:sgtp_flutter/core/di/injector.dart';
import 'package:sgtp_flutter/features/contacts/application/services/contacts_directory_service.dart';
import 'package:sgtp_flutter/features/messaging/data/repositories/chat_storage_gateway_impl.dart';
import 'package:sgtp_flutter/features/settings/application/services/settings_management_service.dart';
import 'package:sgtp_flutter/features/shell/application/services/app_startup_service.dart';
import 'package:sgtp_flutter/features/shell/application/services/home_persistence_service.dart';
import 'package:sgtp_flutter/features/shell/application/services/home_userdir_coordinator.dart';
import 'package:sgtp_flutter/features/shell/application/services/home_userdir_support_service.dart';
import 'package:sgtp_flutter/features/setup/data/repositories/app_backup_repository.dart';
import 'package:sgtp_flutter/features/setup/data/repositories/settings_repository.dart';

void main() {
  testWidgets('App smoke test', (WidgetTester tester) async {
    final settingsRepository = SettingsRepository();
    const chatStorageGateway = DefaultChatStorageGateway();
    final homePersistenceService = HomePersistenceService(
      settingsRepository: settingsRepository,
      chatStorageGateway: chatStorageGateway,
    );
    final homeUserDirSupportService = HomeUserDirSupportService();
    final contactsDirectoryService = ContactsDirectoryService(
      settingsRepository: settingsRepository,
    );
    final appBackupRepository = AppBackupRepository();
    final settingsManagementService = SettingsManagementService(
      settingsRepository: settingsRepository,
      appBackupRepository: appBackupRepository,
    );
    await tester.pumpWidget(
      SgtpApp(
        dependencies: AppDependencies(
          settingsRepository: settingsRepository,
          appBackupRepository: appBackupRepository,
          chatStorageGateway: chatStorageGateway,
          appStartupService: AppStartupService(
            settingsRepository: settingsRepository,
          ),
          contactsDirectoryService: contactsDirectoryService,
          settingsManagementService: settingsManagementService,
          homePersistenceService: homePersistenceService,
          homeUserDirSupportService: homeUserDirSupportService,
          homeUserDirCoordinatorFactory: ({
            required onDirectMessageReady,
            required onStateChanged,
          }) =>
              HomeUserDirCoordinator(
                persistenceService: homePersistenceService,
                supportService: homeUserDirSupportService,
                onDirectMessageReady: onDirectMessageReady,
                onStateChanged: onStateChanged,
              ),
        ),
      ),
    );
    expect(find.byType(MaterialApp), findsOneWidget);
  });
}
