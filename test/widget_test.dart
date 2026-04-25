import 'dart:async';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:cross_file/cross_file.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:sgtp_flutter/core/app/notification_interaction_service.dart';
import 'package:sgtp_flutter/core/app_notifications/custom_app_notifications_controller.dart';
import 'package:sgtp_flutter/core/app_notifications/linux_native_notifications_adapter.dart';
import 'package:sgtp_flutter/core/app/app.dart';
import 'package:sgtp_flutter/core/di/injector.dart';
import 'package:sgtp_flutter/core/network/sgtp_connection_service.dart';
import 'package:sgtp_flutter/core/storage/account_storage_paths.dart';
import 'package:sgtp_flutter/features/contacts/application/services/contacts_directory_service.dart';
import 'package:sgtp_flutter/features/contacts/domain/repositories/i_user_dir_client.dart';
import 'package:sgtp_flutter/features/messaging/application/models/messaging_models.dart';
import 'package:sgtp_flutter/features/messaging/domain/entities/direct_room_binding.dart';
import 'package:sgtp_flutter/features/messaging/domain/entities/sgtp_config.dart';
import 'package:sgtp_flutter/features/messaging/application/services/media_storage_service.dart';
import 'package:sgtp_flutter/features/messaging/application/services/message_notification_service.dart';
import 'package:sgtp_flutter/features/messaging/domain/repositories/chat_storage_gateway.dart';
import 'package:sgtp_flutter/features/messaging/domain/repositories/direct_room_gateway.dart';
import 'package:sgtp_flutter/features/messaging/domain/repositories/i_sgtp_session.dart';
import 'package:sgtp_flutter/features/messaging/domain/repositories/key_package_publisher.dart';
import 'package:sgtp_flutter/features/notifications/application/services/notification_dispatcher.dart';
import 'package:sgtp_flutter/features/notifications/application/services/notification_projection_service.dart';
import 'package:sgtp_flutter/features/notifications/application/services/push_notification_service.dart';
import 'package:sgtp_flutter/features/notifications/application/services/push_message_processor.dart';
import 'package:sgtp_flutter/features/notifications/application/services/push_message_payload_parser.dart';
import 'package:sgtp_flutter/features/notifications/application/services/notification_host_service.dart';
import 'package:sgtp_flutter/features/notifications/domain/entities/notification_account_context.dart';
import 'package:sgtp_flutter/features/notifications/domain/entities/notification_event.dart';
import 'package:sgtp_flutter/features/notifications/domain/entities/notification_host_status.dart';
import 'package:sgtp_flutter/features/notifications/domain/entities/notification_inbox_record.dart';
import 'package:sgtp_flutter/features/notifications/domain/repositories/notification_account_context_resolver.dart';
import 'package:sgtp_flutter/features/notifications/domain/repositories/notification_host_platform_adapter.dart';
import 'package:sgtp_flutter/features/notifications/domain/repositories/notification_inbox_store.dart';
import 'package:sgtp_flutter/features/notifications/domain/repositories/push_device_registry.dart';
import 'package:sgtp_flutter/features/notifications/domain/repositories/push_messaging_client.dart';
import 'package:sgtp_flutter/features/notifications/domain/repositories/push_notification_sink.dart';
import 'package:sgtp_flutter/features/notifications/domain/repositories/push_token_registrar.dart';
import 'package:sgtp_flutter/features/notifications/data/services/app_notification_presenter.dart';
import 'package:sgtp_flutter/features/settings/application/services/settings_management_service.dart';
import 'package:sgtp_flutter/features/setup/data/repositories/app_backup_repository.dart';
import 'package:sgtp_flutter/features/setup/data/repositories/settings_repository.dart';
import 'package:sgtp_flutter/features/setup/domain/entities/node.dart';
import 'package:sgtp_flutter/features/shell/application/services/app_startup_service.dart';
import 'package:sgtp_flutter/features/shell/application/services/home_persistence_service.dart';
import 'package:sgtp_flutter/features/shell/application/services/home_userdir_coordinator.dart';
import 'package:sgtp_flutter/features/shell/application/services/home_userdir_support_service.dart';

class _FakeUserDirClient implements IUserDirClient {
  @override
  String get label => 'test-userdir';

  @override
  bool get isConnected => true;

  @override
  Stream<UserDirMeta> get notifyStream => const Stream<UserDirMeta>.empty();

  @override
  Stream<UserDirFriendNotify> get friendNotifyStream =>
      const Stream<UserDirFriendNotify>.empty();

  @override
  Future<void> connect() async {}

  @override
  void close() {}

  @override
  Future<UserDirMeta?> getMeta(Uint8List pubkey) async => null;

  @override
  Future<UserDirProfile?> getProfile(Uint8List pubkey) async => null;

  @override
  Future<({bool ok, String? errorMessage})> registerWithResult({
    required String username,
    required String fullname,
    required Uint8List pubkey,
    required Uint8List avatarBytes,
    required SimpleKeyPairData identityKeyPair,
    String? deviceId,
  }) async =>
      (ok: true, errorMessage: null);

  @override
  Future<List<UserDirMeta>> search(String query, {int limit = 20}) async =>
      const [];

  @override
  Future<bool> sendFriendDelete({
    required Uint8List myPubkey,
    required Uint8List peerPubkey,
    required SimpleKeyPairData identityKeyPair,
  }) async =>
      true;

  @override
  Future<bool> sendFriendRequest({
    required Uint8List myPubkey,
    required Uint8List peerPubkey,
    required SimpleKeyPairData identityKeyPair,
  }) async =>
      true;

  @override
  Future<bool> sendFriendResponse({
    required Uint8List myPubkey,
    required Uint8List requesterPubkey,
    required bool accept,
    required SimpleKeyPairData identityKeyPair,
  }) async =>
      true;

  @override
  Future<List<UserDirFriendState>?> friendSync({
    required Uint8List myPubkey,
    required SimpleKeyPairData identityKeyPair,
  }) async =>
      const [];

  @override
  Future<bool> subscribe(List<Uint8List> pubkeys) async => true;
}

class _FakeSgtpSession implements ISgtpSession {
  @override
  String get roomUUIDHex => '00000000000000000000000000000000';

  @override
  String get myUUIDHex => '00000000000000000000000000000000';

  @override
  List<String> get peerUUIDs => const [];

  @override
  Map<String, String> get peerPublicKeys => const {};

  @override
  Stream<SgtpEvent> get events => const Stream<SgtpEvent>.empty();

  @override
  Future<void> close() async {}

  @override
  Future<void> connect() async {}

  @override
  Future<void> disconnect() async {}

  @override
  Future<PersistedHistoryBatchResult> replayPersistedHistoryBatch({
    required int offsetFromEnd,
    required int limit,
  }) async =>
      const PersistedHistoryBatchResult(loaded: 0, total: 0);

  @override
  Future<void> probeConnection() async {}

  @override
  Future<void> sendChatMeta(String name, Uint8List? avatarBytes) async {}

  @override
  Future<void> sendImage(Uint8List bytes, String name, String mime) async {}

  @override
  Future<void> sendMessage(
    String text, {
    String? replyToId,
    String? replyToContent,
    String? replyToSender,
  }) async {}

  @override
  Future<void> sendMessageRead(String messageId) async {}

  @override
  Future<void> sendVideo(XFile xFile, String name, String mime) async {}

  @override
  Future<void> sendVideoNote(Uint8List bytes, String mime) async {}

  @override
  Future<void> sendVideoNoteFromXFile(
    XFile xFile,
    String mime, {
    VideoNoteMetadata? metadata,
  }) async {}

  @override
  Future<void> sendVoice(Uint8List bytes, String mime) async {}

  @override
  void sendReaction(String messageId, String emoji, bool adding) {}

  @override
  void setUserAvatar(Uint8List? bytes) {}

}

class _FakeDirectRoomGateway implements DirectRoomGateway {
  @override
  Future<DirectRoomBinding> ensureDirectRoom({
    required SgtpConfig config,
    required Uint8List targetUserPublicKey,
  }) async {
    return const DirectRoomBinding(
      roomId: '00000000000000000000000000000000',
      alreadyExisted: true,
    );
  }
}

class _FakeKeyPackagePublisher implements KeyPackagePublisher {
  @override
  Future<void> ensureUploaded(SgtpConfig config) async {}

  @override
  void invalidateForConfig(SgtpConfig config) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('App smoke test', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});

    final accountStoragePaths = createAccountStoragePaths();
    final settingsRepository = SettingsRepository();
    final appBackupRepository = AppBackupRepository();
    final chatStorageGateway = _FakeChatStorageGateway();
    final fakeUserDirClient = _FakeUserDirClient();
    final settingsManagementService = SettingsManagementService(
      settingsRepository: settingsRepository,
      appBackupRepository: appBackupRepository,
      userDirClientFactory: (NodeConfig node, _) => fakeUserDirClient,
    );
    final homePersistenceService = HomePersistenceService(
      settingsManagementService: settingsManagementService,
      chatStorageGateway: chatStorageGateway,
    );
    final homeUserDirSupportService = HomeUserDirSupportService();
    final contactsDirectoryService = ContactsDirectoryService(
      settingsManagementService: settingsManagementService,
    );
    final customController = CustomAppNotificationsController();
    final notificationDispatcher = NotificationDispatcher(
      projectionService: const NotificationProjectionService(),
      inboxStore: _MemoryNotificationInboxStore(),
      presenter: AppNotificationPresenter(
        settingsManagementService: settingsManagementService,
        customController: customController,
        linuxNativeAdapter: _FakeLinuxNativeNotificationsAdapter(),
      ),
      accountContextResolver: _StaticNotificationAccountContextResolver(),
    );
    final messageNotificationService = MessageNotificationService(
      notificationDispatcher: notificationDispatcher,
      interactionService: NotificationInteractionService(),
    );
    final notificationHostService = NotificationHostService(
      platformAdapter: _FakeNotificationHostPlatformAdapter(),
    );
    final pushNotificationService = PushNotificationService(
      messagingClient: _FakePushMessagingClient(),
      deviceRegistry: _FakePushDeviceRegistry(),
      tokenRegistrar: _FakePushTokenRegistrar(),
      messageProcessor: PushMessageProcessor(
        payloadParser: const PushMessagePayloadParser(),
        deviceRegistry: _FakePushDeviceRegistry(),
        notificationSink: _NoopPushNotificationSink(),
      ),
      platformCode: 2,
    );
    final mediaStorageService = createMessagingMediaStorageService(
      accountStoragePaths: accountStoragePaths,
    );

    await tester.pumpWidget(
      SgtpApp(
        dependencies: AppDependencies(
          chatStorageGateway: chatStorageGateway,
          appStartupService: AppStartupService(
            settingsManagementService: settingsManagementService,
          ),
          contactsDirectoryService: contactsDirectoryService,
          settingsManagementService: settingsManagementService,
          homePersistenceService: homePersistenceService,
          homeUserDirSupportService: homeUserDirSupportService,
          sgtpConnectionService: SgtpConnectionService(),
          directRoomGateway: _FakeDirectRoomGateway(),
          keyPackagePublisher: _FakeKeyPackagePublisher(),
          mediaStorageService: mediaStorageService,
          messageNotificationService: messageNotificationService,
          notificationHostService: notificationHostService,
          pushNotificationService: pushNotificationService,
          sgtpSessionFactory: (_) => _FakeSgtpSession(),
          customAppNotificationsController: customController,
          notificationInteractionService: NotificationInteractionService(),
          homeUserDirCoordinatorFactory: ({
            required onDirectMessageReady,
            required onStateChanged,
          }) =>
              HomeUserDirCoordinator(
            persistenceService: homePersistenceService,
            supportService: homeUserDirSupportService,
            messageNotificationService: messageNotificationService,
            userDirClient: fakeUserDirClient,
            onDirectMessageReady: onDirectMessageReady,
            onStateChanged: onStateChanged,
          ),
        ),
      ),
    );

    expect(find.byType(MaterialApp), findsOneWidget);
  });
}

class _FakeChatStorageGateway implements ChatStorageGateway {
  @override
  ChatHistoryStore historyForChat({
    required String accountId,
    required String serverAddress,
    required String chatUUID,
  }) =>
      _FakeChatHistoryStore();

  @override
  Future<int> migrateServerAddress({
    required String accountId,
    required String fromServerAddress,
    required String toServerAddress,
  }) async =>
      0;

  @override
  ChatMetadataStore metadataForAccount(String accountId) =>
      _FakeChatMetadataStore();
}

class _FakeChatHistoryStore implements ChatHistoryStore {
  @override
  Future<void> clear() async {}
}

class _FakeChatMetadataStore implements ChatMetadataStore {
  @override
  Future<void> deleteChat(String uuid, {String? serverAddress}) async {}

  @override
  Future<ChatMetadata?> loadChat(String uuid, {String? serverAddress}) async =>
      null;

  @override
  Future<List<ChatMetadata>> loadAllChats() async => const [];

  @override
  Future<void> saveChat(ChatMetadata metadata) async {}

  @override
  Future<void> updateChat(ChatMetadata metadata) async {}
}

class _MemoryNotificationInboxStore implements NotificationInboxStore {
  @override
  Future<void> closeAccount(String accountId) async {}

  @override
  Future<NotificationInboxRecord?> findByDedupKey(
    String accountId,
    String dedupKey,
  ) async =>
      null;

  @override
  Future<NotificationInboxRecord?> findLatestByCollapseKey(
    String accountId,
    String collapseKey,
  ) async =>
      null;

  @override
  Future<void> save(NotificationInboxRecord record) async {}
}

class _StaticNotificationAccountContextResolver
    implements NotificationAccountContextResolver {
  @override
  Future<NotificationAccountContext> resolve(String accountId) async =>
      NotificationAccountContext(accountId: accountId, genericOnly: false);
}

class _FakeNotificationHostPlatformAdapter
    implements NotificationHostPlatformAdapter {
  @override
  Future<NotificationHostStatus> initialize() async =>
      NotificationHostStatus.unsupported;

  @override
  Future<bool> isRunning() async => false;

  @override
  Future<void> startForAccount(String accountId) async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> stopForAccount(String accountId) async {}
}

class _FakePushMessagingClient implements PushMessagingClient {
  @override
  Future<String?> getToken() async => null;

  @override
  Future<void> initialize() async {}

  @override
  Stream<Map<String, String>> get onForegroundMessage =>
      const Stream<Map<String, String>>.empty();

  @override
  Stream<String> get onTokenRefresh => const Stream<String>.empty();

  @override
  Future<bool> requestPermission() async => false;
}

class _FakePushDeviceRegistry implements PushDeviceRegistry {
  @override
  Future<String> loadDeviceId(String accountId) async => 'device-test';

  @override
  Future<String?> resolveAccountId({String? accountId, String? deviceId}) async =>
      accountId;
}

class _FakePushTokenRegistrar implements PushTokenRegistrar {
  @override
  Future<void> registerToken({
    required String accountId,
    required String deviceId,
    required int platformCode,
    required String pushToken,
    required bool isEnabled,
  }) async {}
}

class _NoopPushNotificationSink implements PushNotificationSink {
  @override
  Future<void> showFriendRequest(NotificationEvent event) async {}

  @override
  Future<void> showMessage(NotificationEvent event) async {}
}

class _FakeLinuxNativeNotificationsAdapter
    implements LinuxNativeNotificationsAdapter {
  @override
  Future<void> dismiss(String handleId) async {}

  @override
  Future<void> dismissAll() async {}

  @override
  Future<bool> isSupported({bool requiresActions = false}) async => false;

  @override
  Future<void> show(LinuxNativeNotificationRequest request) async {}
}
