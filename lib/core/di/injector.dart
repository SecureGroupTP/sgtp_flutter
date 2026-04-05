import 'dart:typed_data';

import 'package:sgtp_flutter/features/contacts/data/services/userdir_client.dart';
import 'package:sgtp_flutter/features/contacts/domain/repositories/i_user_dir_client.dart';
import 'package:sgtp_flutter/features/messaging/data/repositories/chat_storage_gateway_impl.dart';
import 'package:sgtp_flutter/features/messaging/data/services/sgtp_client.dart';
import 'package:sgtp_flutter/features/messaging/domain/repositories/chat_storage_gateway.dart';
import 'package:sgtp_flutter/features/messaging/domain/repositories/i_sgtp_session.dart';
import 'package:sgtp_flutter/features/contacts/application/services/contacts_directory_service.dart';
import 'package:sgtp_flutter/features/settings/application/services/settings_management_service.dart';
import 'package:sgtp_flutter/features/shell/application/models/home_userdir_models.dart';
import 'package:sgtp_flutter/features/shell/application/services/app_startup_service.dart';
import 'package:sgtp_flutter/features/shell/application/services/home_userdir_coordinator.dart';
import 'package:sgtp_flutter/features/shell/application/services/home_persistence_service.dart';
import 'package:sgtp_flutter/features/shell/application/services/home_userdir_support_service.dart';
import 'package:sgtp_flutter/features/setup/data/repositories/app_backup_repository.dart';
import 'package:sgtp_flutter/features/setup/data/repositories/settings_repository.dart';

class AppDependencies {
  AppDependencies({
    required this.chatStorageGateway,
    required this.appStartupService,
    required this.contactsDirectoryService,
    required this.settingsManagementService,
    required this.homePersistenceService,
    required this.homeUserDirSupportService,
    required this.sgtpSessionFactory,
    required this.homeUserDirCoordinatorFactory,
  });

  final ChatStorageGateway chatStorageGateway;
  final AppStartupService appStartupService;
  final ContactsDirectoryService contactsDirectoryService;
  final SettingsManagementService settingsManagementService;
  final HomePersistenceService homePersistenceService;
  final HomeUserDirSupportService homeUserDirSupportService;
  final SgtpSessionFactory sgtpSessionFactory;
  final HomeUserDirCoordinator Function({
    required Future<void> Function(
      String roomUUIDHex,
      String peerHex,
      String displayName,
      Uint8List? avatarBytes,
    ) onDirectMessageReady,
    required void Function(HomeUserDirState state) onStateChanged,
  }) homeUserDirCoordinatorFactory;
}

class AppInjector {
  static Future<AppDependencies> build() async {
    final settingsRepository = SettingsRepository();
    final appBackupRepository = AppBackupRepository();
    final settingsManagementService = SettingsManagementService(
      settingsRepository: settingsRepository,
      appBackupRepository: appBackupRepository,
    );
    const chatStorageGateway = DefaultChatStorageGateway();
    final homePersistenceService = HomePersistenceService(
      settingsManagementService: settingsManagementService,
      chatStorageGateway: chatStorageGateway,
    );
    final homeUserDirSupportService = HomeUserDirSupportService();

    SgtpSessionFactory sgtpSessionFactory = (config) => SgtpClient(config);
    UserDirClientFactory userDirClientFactory = UserDirClient.forNode;

    final contactsDirectoryService = ContactsDirectoryService(
      settingsManagementService: settingsManagementService,
      userDirClientFactory: userDirClientFactory,
    );
    return AppDependencies(
      chatStorageGateway: chatStorageGateway,
      appStartupService: AppStartupService(
        settingsManagementService: settingsManagementService,
      ),
      contactsDirectoryService: contactsDirectoryService,
      settingsManagementService: settingsManagementService,
      homePersistenceService: homePersistenceService,
      homeUserDirSupportService: homeUserDirSupportService,
      sgtpSessionFactory: sgtpSessionFactory,
      homeUserDirCoordinatorFactory: ({
        required onDirectMessageReady,
        required onStateChanged,
      }) =>
          HomeUserDirCoordinator(
            persistenceService: homePersistenceService,
            supportService: homeUserDirSupportService,
            userDirClientFactory: userDirClientFactory,
            onDirectMessageReady: onDirectMessageReady,
            onStateChanged: onStateChanged,
          ),
    );
  }
}
