import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:sgtp_flutter/core/network/events/connection_events.dart';
import 'package:sgtp_flutter/core/network/sgtp_connection_service.dart';
import 'package:sgtp_flutter/features/messaging/application/viewmodels/rooms/rooms_bloc.dart';
import 'package:sgtp_flutter/features/messaging/application/viewmodels/rooms/rooms_event.dart';
import 'package:sgtp_flutter/features/messaging/application/services/media_storage_service.dart';
import 'package:sgtp_flutter/features/messaging/application/services/message_notification_service.dart';
import 'package:sgtp_flutter/features/notifications/application/services/notification_host_service.dart';
import 'package:sgtp_flutter/features/messaging/domain/entities/direct_room_binding.dart';
import 'package:sgtp_flutter/features/messaging/domain/entities/sgtp_config.dart';
import 'package:sgtp_flutter/features/messaging/domain/repositories/chat_storage_gateway.dart';
import 'package:sgtp_flutter/features/messaging/domain/repositories/direct_room_gateway.dart';
import 'package:sgtp_flutter/features/messaging/domain/repositories/i_sgtp_session.dart';
import 'package:sgtp_flutter/features/messaging/domain/repositories/key_package_publisher.dart';
import 'package:sgtp_flutter/features/settings/application/services/settings_management_service.dart';
import 'package:sgtp_flutter/features/shell/application/models/home_models.dart';
import 'package:sgtp_flutter/features/shell/application/models/home_userdir_models.dart';
import 'package:sgtp_flutter/features/shell/application/services/home_persistence_service.dart';
import 'package:sgtp_flutter/features/contacts/domain/repositories/i_user_dir_client.dart';
import 'package:sgtp_flutter/features/shell/application/services/home_userdir_coordinator.dart';
import 'package:sgtp_flutter/features/shell/application/services/home_userdir_support_service.dart';
import 'package:sgtp_flutter/features/shell/application/viewmodels/home_view_state.dart';
import 'package:sgtp_flutter/features/setup/domain/entities/contact_directory_models.dart';

class HomeCubit extends Cubit<HomeViewState> {
  HomeCubit({
    required String accountId,
    required SgtpConfig initialConfig,
    required Map<String, String> nicknames,
    required String serverAddress,
    required Uint8List? userAvatar,
    required List<ContactEntry> initialContacts,
    required SettingsManagementService settingsManagementService,
    required ChatStorageGateway chatStorageGateway,
    required SgtpConnectionService sgtpConnectionService,
    required DirectRoomGateway directRoomGateway,
    required KeyPackagePublisher keyPackagePublisher,
    required MessagingMediaStorageService mediaStorageService,
    required MessageNotificationService messageNotificationService,
    required NotificationHostService notificationHostService,
    required SgtpSessionFactory sessionFactory,
    required HomePersistenceService homePersistenceService,
    required HomeUserDirSupportService homeUserDirSupportService,
    required HomeUserDirCoordinator Function({
      required Future<void> Function(
        String roomUUIDHex,
        String peerHex,
        String displayName,
        Uint8List? avatarBytes,
      ) onDirectMessageReady,
      required void Function(HomeUserDirState state) onStateChanged,
    }) homeUserDirCoordinatorFactory,
  })  : _settingsManagementService = settingsManagementService,
        _chatStorageGateway = chatStorageGateway,
        _sgtpConnection = sgtpConnectionService,
        _directRoomGateway = directRoomGateway,
        _keyPackagePublisher = keyPackagePublisher,
        _mediaStorageService = mediaStorageService,
        _messageNotificationService = messageNotificationService,
        _notificationHostService = notificationHostService,
        _sessionFactory = sessionFactory,
        _homePersistence = homePersistenceService,
        _userDirSupport = homeUserDirSupportService,
        _accountId = accountId,
        _config = initialConfig,
        _nicknames = Map.from(nicknames),
        _serverAddress = serverAddress,
        _userAvatar = userAvatar,
        _contacts = List.from(initialContacts),
        super(HomeViewState(
          accountId: accountId,
          config: initialConfig,
          nicknames: nicknames,
          serverAddress: serverAddress,
          userAvatar: userAvatar,
          contacts: initialContacts,
          connectionStatus: sgtpConnectionService.status,
          connectionError: sgtpConnectionService.lastError,
        )) {
    _connectionStatus = _sgtpConnection.status;
    _connectionError = _sgtpConnection.lastError;
    _connectionSub = _sgtpConnection.events.listen(_onConnectionEvent);
    _userDirCoordinator = homeUserDirCoordinatorFactory(
      onDirectMessageReady: _upsertDmChat,
      onStateChanged: _applyCoordinatorState,
    );
    _roomsBloc = RoomsBloc(
      accountId: accountId,
      baseConfig: initialConfig,
      nicknames: _nicknames,
      settingsRepository: settingsManagementService,
      chatStorage: chatStorageGateway,
      connectionService: sgtpConnectionService,
      serverAddress: serverAddress,
      mediaStorageService: mediaStorageService,
      messageNotificationService: messageNotificationService,
      sessionFactory: sessionFactory,
      userAvatar: userAvatar,
    );
    unawaited(_loadNicknameAndInitUserDir());
    unawaited(_notificationHostService.activateAccount(accountId));
  }

  final SettingsManagementService _settingsManagementService;
  final ChatStorageGateway _chatStorageGateway;
  final SgtpConnectionService _sgtpConnection;
  final DirectRoomGateway _directRoomGateway;
  final KeyPackagePublisher _keyPackagePublisher;
  final MessagingMediaStorageService _mediaStorageService;
  final MessageNotificationService _messageNotificationService;
  final NotificationHostService _notificationHostService;
  final SgtpSessionFactory _sessionFactory;
  final HomePersistenceService _homePersistence;
  final HomeUserDirSupportService _userDirSupport;
  StreamSubscription<SgtpConnectionStateChanged>? _connectionSub;

  late HomeUserDirCoordinator _userDirCoordinator;

  /// Exposes the active user-directory client for read-only use by other cubits
  /// (e.g. contact search). Do NOT close the returned client.
  IUserDirClient? get activeUserDirClient => _userDirCoordinator.activeClient;
  late RoomsBloc _roomsBloc;

  String _accountId;
  SgtpConfig _config;
  Map<String, String> _nicknames;
  String _serverAddress;
  Uint8List? _userAvatar;
  List<ContactEntry> _contacts;
  ResolvedUserDirNode? _resolvedNode;
  Map<String, ContactProfile> _contactProfiles = {};
  Map<String, FriendStateRecord> _friendStates = {};
  String _nickname = '';
  String _username = '';
  SgtpConnectionStatus _connectionStatus = SgtpConnectionStatus.disconnected;
  String? _connectionError;
  int _currentTabIndex = 0;

  RoomsBloc get roomsBloc => _roomsBloc;

  // ── Intent: Change tab ──────────────────────────────────────────────────

  void setTabIndex(int index) {
    _currentTabIndex = index;
    _buildState();
    if (index == 1) {
      unawaited(_refreshContactsFromServer());
    }
  }

  // ── Intent: Config changed (from settings) ─────────────────────────────

  void onConfigChanged(
    String accountId,
    SgtpConfig newConfig,
    Map<String, String> newNicknames,
    String newServer,
    List<ContactEntry> contactEntries,
  ) {
    _accountId = accountId;
    _config = newConfig;
    _contacts = List.from(contactEntries);
    _nicknames = {for (final e in contactEntries) e.hexKey: e.name};
    _serverAddress = newServer;
    _userAvatar = null;
    _nickname = '';
    _username = '';
    _contactProfiles = {};
    _friendStates = {};
    _connectionError = null;
    unawaited(_notificationHostService.activateAccount(accountId));

    unawaited(_sgtpConnection.configure(newConfig));
    unawaited(_userDirCoordinator.dispose());
    _roomsBloc.close();
    _roomsBloc = RoomsBloc(
      accountId: _accountId,
      baseConfig: newConfig,
      nicknames: _nicknames,
      settingsRepository: _settingsManagementService,
      chatStorage: _chatStorageGateway,
      connectionService: _sgtpConnection,
      serverAddress: newServer,
      mediaStorageService: _mediaStorageService,
      messageNotificationService: _messageNotificationService,
      userAvatar: null,
      sessionFactory: _sessionFactory,
    );
    _pushContactAvatarsToRooms();
    _buildState();
    unawaited(_loadNicknameAndInitUserDir());
  }

  // ── Intent: User avatar changed ─────────────────────────────────────────

  void onUserAvatarChanged(Uint8List? avatar) {
    _userAvatar = avatar;
    _roomsBloc.setUserAvatar(avatar);
    _buildState();
    unawaited(_syncProfileToUserDir(force: true));
  }

  // ── Intent: Nickname changed ────────────────────────────────────────────

  void onNicknameChanged(String nickname) {
    if (_nickname == nickname) return;
    _nickname = nickname;
    _buildState();
    unawaited(_syncProfileToUserDir(force: true));
  }

  // ── Intent: Username changed ────────────────────────────────────────────

  Future<String?> onUsernameChanged(String username) async {
    final next = _userDirSupport.normalizeUsername(username) ?? '';
    if (_username == next) return null;
    _username = next;
    _buildState();
    await _ensureShellConnection();
    final error = await _userDirCoordinator.registerSelf(
      _buildUserDirSession(),
      force: true,
    );
    await _ensureShellKeyPackagesUploaded();
    return error;
  }

  // ── Intent: Contacts changed ───────────────────────────────────────────

  void onContactsChanged(List<ContactEntry> entries) {
    final old = List<ContactEntry>.from(_contacts);
    _contacts = entries;
    _nicknames = {for (final e in entries) e.hexKey: e.name};
    _roomsBloc.add(RoomsUpdateNicknames(
      {for (final e in entries) e.hexKey: e.name},
    ));
    _pushContactAvatarsToRooms();
    _buildState();
    unawaited(_syncContactsWithUserDir(old, entries));
  }

  // ── Intent: Respond to friend request ───────────────────────────────────

  Future<bool> respondToFriend(String peerHex, bool accept) {
    return _respondToFriend(peerHex, accept);
  }

  Future<bool> _respondToFriend(String peerHex, bool accept) async {
    await _ensureShellConnection();
    return _userDirCoordinator.respondToFriend(
      session: _buildUserDirSession(),
      peerHex: peerHex,
      accept: accept,
    );
  }

  // ── Intent: Open DM room ───────────────────────────────────────────────

  Future<DirectRoomBinding?> openDm(String peerPubkeyHex) async {
    final peerHex = peerPubkeyHex.trim().toLowerCase();
    if (peerHex.length != 64) return null;

    await _ensureShellConnection();
    final binding = await _directRoomGateway.ensureDirectRoom(
      config: _config.copyWith(accountId: _accountId),
      targetUserPublicKey: _userDirSupport.hexToBytes32(peerHex),
    );
    final display = _resolveDirectMessageDisplay(peerHex);
    await _homePersistence.upsertDirectMessageChat(
      accountId: _accountId,
      roomUUID: binding.roomId,
      serverAddress: _serverAddress,
      displayName: display.$1,
      avatarBytes: display.$2,
      remoteRoomId: binding.roomId,
    );
    final existing = _friendStates[peerHex];
    if (existing != null &&
        existing.statusEnum == FriendStatus.friend &&
        existing.roomUUIDHex != binding.roomId) {
      _friendStates = {
        ..._friendStates,
        peerHex: existing.copyWith(
          roomUUIDHex: binding.roomId,
          updatedAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
        ),
      };
    }
    _currentTabIndex = 0;
    _buildState();
    return binding;
  }

  // ── Intent: Show add room sheet (accessed by FAB) ───────────────────────

  // This is handled by the Screen — it calls roomsPageKey.currentState.showAddSheet()

  // ── Intent: Delete all data ─────────────────────────────────────────────

  // Handled in SettingsCubit. The Screen listens for this and navigates.

  // ── Private ─────────────────────────────────────────────────────────────

  void _buildState() {
    emit(HomeViewState(
      accountId: _accountId,
      config: _config,
      nicknames: Map.unmodifiable(_nicknames),
      serverAddress: _serverAddress,
      userAvatar: _userAvatar,
      contacts: List.unmodifiable(_contacts),
      contactProfiles: Map.unmodifiable(_contactProfiles),
      friendStates: Map.unmodifiable(_friendStates),
      nickname: _nickname,
      username: _username,
      connectionStatus: _connectionStatus,
      connectionError: _connectionError,
      currentTabIndex: _currentTabIndex,
    ));
  }

  Future<void> _loadNicknameAndInitUserDir() async {
    final targetAccountId = _accountId.trim();
    if (targetAccountId.isNotEmpty) {
      final accountState = await _homePersistence.loadAccountState(
        targetAccountId,
      );
      if (targetAccountId != _accountId.trim()) return;
      _nickname = accountState.nickname;
      final rawUsername = accountState.username;
      final normalized = _userDirSupport.normalizeUsername(rawUsername);
      _username = normalized ?? '';
      _userAvatar = accountState.userAvatar;
      _roomsBloc.setUserAvatar(_userAvatar);
      if (rawUsername.trim() != _username) {
        await _homePersistence.saveUsername(targetAccountId, _username);
        if (targetAccountId != _accountId.trim()) return;
      }
      _buildState();
    }
    if (targetAccountId != _accountId.trim()) return;
    _resolvedNode = await _homePersistence.resolveUserDirNode(
      accountId: _accountId,
      currentNodeId: _config.nodeId,
    );
    await _ensureShellConnection();
    await _userDirCoordinator.start(_buildUserDirSession());
    await _ensureShellKeyPackagesUploaded();
  }

  void _pushContactAvatarsToRooms() {
    _roomsBloc.add(
      RoomsUpdateContactAvatars(
        _userDirSupport.buildContactAvatarsByPubkey(
          contacts: _contacts,
          contactProfiles: _contactProfiles,
        ),
      ),
    );
  }

  Future<void> _upsertDmChat(
    String roomUUIDHex,
    String peerHex,
    String displayName,
    Uint8List? avatarBytes,
  ) async {
    final room = roomUUIDHex.toLowerCase().replaceAll('-', '');
    if (room.length != 32) return;
    await _homePersistence.upsertDirectMessageChat(
      accountId: _accountId,
      roomUUID: room,
      serverAddress: _serverAddress,
      displayName: displayName,
      avatarBytes: avatarBytes,
      remoteRoomId: room,
    );
  }

  (String, Uint8List?) _resolveDirectMessageDisplay(String peerHex) {
    final profile = _contactProfiles[peerHex];
    final fullName = (profile?.fullname ?? '').trim();
    final username =
        (profile?.username ?? '').trim().replaceFirst(RegExp(r'^@+'), '');
    final fallback = (_nicknames[peerHex] ?? '').trim();
    final displayName = fullName.isNotEmpty
        ? fullName
        : (username.isNotEmpty
            ? username
            : (fallback.isNotEmpty ? fallback : 'Friend'));
    return (displayName, profile?.avatarBytes);
  }

  HomeUserDirSession _buildUserDirSession() {
    return HomeUserDirSession(
      accountId: _accountId,
      config: _config,
      contacts: _contacts,
      nicknames: _nicknames,
      nickname: _nickname,
      username: _username,
      userAvatar: _userAvatar,
      serverAddress: _serverAddress,
      resolvedNode: _resolvedNode,
    );
  }

  void _applyCoordinatorState(HomeUserDirState coordState) {
    if (isClosed) return;
    _contactProfiles =
        Map<String, ContactProfile>.from(coordState.contactProfiles);
    _friendStates =
        Map<String, FriendStateRecord>.from(coordState.friendStates);
    _contacts = List<ContactEntry>.from(coordState.contacts);
    _nicknames = Map<String, String>.from(coordState.nicknames);
    _roomsBloc.add(RoomsUpdateNicknames(_nicknames));
    _pushContactAvatarsToRooms();
    _buildState();
  }

  Future<void> _refreshContactsFromServer() {
    return _refreshContactsFromServerConnected();
  }

  Future<void> _refreshContactsFromServerConnected() async {
    await _ensureShellConnection();
    await _userDirCoordinator.refresh(_buildUserDirSession());
  }

  Future<void> _syncProfileToUserDir({required bool force}) async {
    await _ensureShellConnection();
    await _userDirCoordinator.registerSelf(
      _buildUserDirSession(),
      force: force,
    );
    await _ensureShellKeyPackagesUploaded();
  }

  Future<void> _syncContactsWithUserDir(
    List<ContactEntry> previousContacts,
    List<ContactEntry> nextContacts,
  ) async {
    await _ensureShellConnection();
    await _userDirCoordinator.applyContactChanges(
      session: _buildUserDirSession(),
      previousContacts: previousContacts,
      nextContacts: nextContacts,
      nextNicknames: {for (final e in nextContacts) e.hexKey: e.name},
    );
  }

  Future<void> _ensureShellConnection() async {
    _connectionError = null;
    try {
      await _sgtpConnection.configure(_config);
      await _sgtpConnection.ensureConnected();
    } catch (e) {
      _connectionError = '$e';
      _buildState();
      rethrow;
    }
  }

  Future<void> _ensureShellKeyPackagesUploaded() async {
    if (!_userDirCoordinator.profileRegisteredOnServer) {
      return;
    }
    await _keyPackagePublisher.ensureUploaded(
      _config.copyWith(accountId: _accountId),
    );
  }

  void _onConnectionEvent(SgtpConnectionStateChanged event) {
    if (isClosed) return;
    _connectionStatus = event.status;
    _connectionError = event.errorMessage;
    _buildState();
  }

  @override
  Future<void> close() async {
    await _connectionSub?.cancel();
    await _notificationHostService.deactivateAccount(_accountId);
    unawaited(_userDirCoordinator.dispose());
    _roomsBloc.close();
    unawaited(_sgtpConnection.disconnect());
    await super.close();
  }
}
