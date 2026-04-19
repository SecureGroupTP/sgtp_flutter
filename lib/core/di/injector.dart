import 'dart:typed_data';

import 'package:sgtp_flutter/core/network/sgtp_connection_service.dart';
import 'package:sgtp_flutter/core/network/sgtp_rpc_client.dart';
import 'package:sgtp_flutter/core/storage/account_storage_paths.dart';
import 'package:sgtp_flutter/core/storage/main_database_factory.dart';
import 'package:sgtp_flutter/core/storage/storage_key_service.dart';
import 'package:sgtp_flutter/core/network/transport/http_protocol_transport.dart';
import 'package:sgtp_flutter/core/network/transport/tcp_sgtp_transport.dart';
import 'package:sgtp_flutter/core/network/transport/websocket_sgtp_transport.dart';
import 'package:sgtp_flutter/core/sgtp_server_options.dart';
import 'package:sgtp_flutter/core/sgtp_transport.dart';
import 'package:sgtp_flutter/features/contacts/data/services/userdir_client.dart';
import 'package:sgtp_flutter/features/messaging/data/repositories/chat_storage_gateway_impl.dart';
import 'package:sgtp_flutter/features/messaging/data/repositories/shared_direct_room_gateway.dart';
import 'package:sgtp_flutter/features/messaging/application/services/media_storage_service.dart';
import 'package:sgtp_flutter/features/messaging/data/services/openmls_runtime.dart';
import 'package:sgtp_flutter/features/messaging/data/services/server_v2_chat_session.dart';
import 'package:sgtp_flutter/features/messaging/data/services/shared_key_package_publisher.dart';
import 'package:sgtp_flutter/features/messaging/domain/repositories/direct_room_gateway.dart';
import 'package:sgtp_flutter/features/messaging/domain/entities/sgtp_config.dart';
import 'package:sgtp_flutter/features/messaging/domain/repositories/chat_storage_gateway.dart';
import 'package:sgtp_flutter/features/messaging/domain/repositories/i_sgtp_session.dart';
import 'package:sgtp_flutter/features/messaging/domain/repositories/key_package_publisher.dart';
import 'package:sgtp_flutter/features/contacts/application/services/contacts_directory_service.dart';
import 'package:sgtp_flutter/features/settings/application/services/settings_management_service.dart';
import 'package:sgtp_flutter/features/setup/domain/entities/node.dart';
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
    required this.sgtpConnectionService,
    required this.directRoomGateway,
    required this.keyPackagePublisher,
    required this.mediaStorageService,
    required this.sgtpSessionFactory,
    required this.homeUserDirCoordinatorFactory,
  });

  final ChatStorageGateway chatStorageGateway;
  final AppStartupService appStartupService;
  final ContactsDirectoryService contactsDirectoryService;
  final SettingsManagementService settingsManagementService;
  final HomePersistenceService homePersistenceService;
  final HomeUserDirSupportService homeUserDirSupportService;
  final SgtpConnectionService sgtpConnectionService;
  final DirectRoomGateway directRoomGateway;
  final KeyPackagePublisher keyPackagePublisher;
  final MessagingMediaStorageService mediaStorageService;
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
    final accountStoragePaths = createAccountStoragePaths();
    final storageKeyService = StorageKeyService();
    final mainDatabaseFactory = MainDatabaseFactory(
      accountStoragePaths: accountStoragePaths,
      storageKeyService: storageKeyService,
    );
    final mediaStorageService = createMessagingMediaStorageService(
      accountStoragePaths: accountStoragePaths,
    );
    final settingsRepository = SettingsRepository(
      accountStoragePaths: accountStoragePaths,
      storageKeyService: storageKeyService,
      mainDatabaseFactory: mainDatabaseFactory,
    );
    final appBackupRepository = AppBackupRepository();

    UserDirClient? userDirClientFactory(
        NodeConfig node, SgtpServerOptions opts) {
      if (!opts.supports(node.transport, tls: node.useTls)) return null;
      final port = opts.portFor(node.transport, tls: node.useTls);
      if (port <= 0) return null;
      final fakeSni = node.fakeSni.trim().isEmpty ? null : node.fakeSni.trim();
      final transport = switch (node.transport) {
        SgtpTransportFamily.tcp => TcpSgtpTransport(
            host: node.host,
            port: port,
            useTls: node.useTls,
            fakeSni: fakeSni,
          ),
        SgtpTransportFamily.websocket => WebSocketSgtpTransport(
            host: node.host,
            port: port,
            useTls: node.useTls,
            fakeSni: fakeSni,
          ),
        SgtpTransportFamily.http => HttpProtocolTransport(
            host: node.host,
            port: port,
            useTls: node.useTls,
          ),
      };
      final label =
          '${node.transport.name}${node.useTls ? '+tls' : ''}://${node.host}:$port';
      final rpc = SgtpRpcClient(transport);
      return UserDirClient(
        rpcProvider: () async => rpc,
        label: label,
      );
    }

    final settingsManagementService = SettingsManagementService(
      settingsRepository: settingsRepository,
      appBackupRepository: appBackupRepository,
      userDirClientFactory: userDirClientFactory,
    );
    final chatStorageGateway = DefaultChatStorageGateway(
      mainDatabaseFactory: mainDatabaseFactory,
    );
    final sgtpConnectionService = SgtpConnectionService();
    final sharedUserDirClient = UserDirClient(
      rpcProvider: sgtpConnectionService.ensureConnected,
      label: 'shared-sgtp',
      providerManagesConnection: true,
    );
    final homePersistenceService = HomePersistenceService(
      settingsManagementService: settingsManagementService,
      chatStorageGateway: chatStorageGateway,
    );
    final homeUserDirSupportService = HomeUserDirSupportService();
    final directRoomGateway = SharedDirectRoomGateway(
      connectionService: sgtpConnectionService,
    );
    final openMlsRuntimeFactory = OpenMlsRuntimeFactory(
      accountStoragePaths: accountStoragePaths,
      storageKeyService: storageKeyService,
    );
    final keyPackagePublisher = SharedKeyPackagePublisher(
      connectionService: sgtpConnectionService,
      openMlsRuntimeFactory: openMlsRuntimeFactory,
    );

    // The active chat session runtime is the dedicated OpenMLS-backed
    // implementation. `SgtpClient` remains only as a deprecated compatibility
    // alias and is intentionally not wired here.
    ISgtpSession sgtpSessionFactory(SgtpConfig config) => ServerV2ChatSession(
          config,
          connectionService: sgtpConnectionService,
          openMlsRuntimeFactory: openMlsRuntimeFactory,
          mainDatabaseFactory: mainDatabaseFactory,
        );

    final contactsDirectoryService = ContactsDirectoryService(
      settingsManagementService: settingsManagementService,
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
      sgtpConnectionService: sgtpConnectionService,
      directRoomGateway: directRoomGateway,
      keyPackagePublisher: keyPackagePublisher,
      mediaStorageService: mediaStorageService,
      sgtpSessionFactory: sgtpSessionFactory,
      homeUserDirCoordinatorFactory: ({
        required onDirectMessageReady,
        required onStateChanged,
      }) =>
          HomeUserDirCoordinator(
        persistenceService: homePersistenceService,
        supportService: homeUserDirSupportService,
        userDirClient: sharedUserDirClient,
        onDirectMessageReady: onDirectMessageReady,
        onStateChanged: onStateChanged,
      ),
    );
  }
}
