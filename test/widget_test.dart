import 'dart:async';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:cross_file/cross_file.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:sgtp_flutter/core/app/app.dart';
import 'package:sgtp_flutter/core/di/injector.dart';
import 'package:sgtp_flutter/core/network/sgtp_connection_service.dart';
import 'package:sgtp_flutter/features/contacts/application/services/contacts_directory_service.dart';
import 'package:sgtp_flutter/features/contacts/domain/repositories/i_user_dir_client.dart';
import 'package:sgtp_flutter/features/messaging/data/repositories/chat_storage_gateway_impl.dart';
import 'package:sgtp_flutter/features/messaging/domain/entities/direct_room_binding.dart';
import 'package:sgtp_flutter/features/messaging/domain/entities/sgtp_config.dart';
import 'package:sgtp_flutter/features/messaging/domain/entities/video_note_metadata.dart';
import 'package:sgtp_flutter/features/messaging/domain/repositories/direct_room_gateway.dart';
import 'package:sgtp_flutter/features/messaging/domain/repositories/i_sgtp_session.dart';
import 'package:sgtp_flutter/features/messaging/domain/repositories/key_package_publisher.dart';
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
  Future<bool> requestDirectWelcomeReissue() async => false;

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

  @override
  void updateWhitelist(Set<String> whitelist) {}
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

    final settingsRepository = SettingsRepository();
    final appBackupRepository = AppBackupRepository();
    const chatStorageGateway = DefaultChatStorageGateway();
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
          sgtpSessionFactory: (_) => _FakeSgtpSession(),
          homeUserDirCoordinatorFactory: ({
            required onDirectMessageReady,
            required onStateChanged,
          }) =>
              HomeUserDirCoordinator(
            persistenceService: homePersistenceService,
            supportService: homeUserDirSupportService,
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
