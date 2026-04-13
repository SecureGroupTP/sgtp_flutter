import 'dart:typed_data';

import 'package:sgtp_flutter/core/network/sgtp_rpc_client.dart';
import 'package:sgtp_flutter/core/network/transport/http_protocol_transport.dart';
import 'package:sgtp_flutter/core/sgtp_server_options.dart';
import 'package:sgtp_flutter/core/sgtp_transport.dart';
import 'package:sgtp_flutter/features/contacts/data/services/userdir_client.dart';
import 'package:sgtp_flutter/features/contacts/domain/repositories/i_user_dir_client.dart';
import 'package:sgtp_flutter/features/messaging/data/repositories/chat_storage_gateway_impl.dart';
import 'package:sgtp_flutter/features/messaging/data/services/openmls_chat_session.dart';
import 'package:sgtp_flutter/features/messaging/data/transport/tcp_sgtp_transport.dart';
import 'package:sgtp_flutter/features/messaging/data/transport/websocket_sgtp_transport.dart';
import 'package:sgtp_flutter/features/messaging/domain/repositories/chat_storage_gateway.dart';
import 'package:sgtp_flutter/features/messaging/domain/repositories/i_sgtp_session.dart';
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

    UserDirClientFactory userDirClientFactory =
        (NodeConfig node, SgtpServerOptions opts) {
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
      return UserDirClient(rpc: SgtpRpcClient(transport), label: label);
    };

    final settingsManagementService = SettingsManagementService(
      settingsRepository: settingsRepository,
      appBackupRepository: appBackupRepository,
      userDirClientFactory: userDirClientFactory,
    );
    const chatStorageGateway = DefaultChatStorageGateway();
    final homePersistenceService = HomePersistenceService(
      settingsManagementService: settingsManagementService,
      chatStorageGateway: chatStorageGateway,
    );
    final homeUserDirSupportService = HomeUserDirSupportService();

    // The active chat session runtime is the dedicated chat_core/OpenMLS-backed
    // implementation. `SgtpClient` remains only as a deprecated compatibility
    // alias and is intentionally not wired here.
    final SgtpSessionFactory sgtpSessionFactory =
        (config) => OpenMlsChatSession(config);

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
