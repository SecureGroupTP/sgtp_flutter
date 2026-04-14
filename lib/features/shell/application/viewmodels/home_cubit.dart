import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:sgtp_flutter/core/network/events/connection_events.dart';
import 'package:sgtp_flutter/core/network/sgtp_connection_service.dart';
import 'package:sgtp_flutter/features/messaging/application/viewmodels/rooms/rooms_bloc.dart';
import 'package:sgtp_flutter/features/messaging/application/viewmodels/rooms/rooms_event.dart';
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
    required List<WhitelistEntry> initialWhitelist,
    required SettingsManagementService settingsManagementService,
    required ChatStorageGateway chatStorageGateway,
    required SgtpConnectionService sgtpConnectionService,
    required DirectRoomGateway directRoomGateway,
    required KeyPackagePublisher keyPackagePublisher,
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
        _sessionFactory = sessionFactory,
        _homePersistence = homePersistenceService,
        _userDirSupport = homeUserDirSupportService,
        _accountId = accountId,
        _config = initialConfig,
        _nicknames = Map.from(nicknames),
        _serverAddress = serverAddress,
        _userAvatar = userAvatar,
        _whitelist = List.from(initialWhitelist),
        super(HomeViewState(
          accountId: accountId,
          config: initialConfig,
          nicknames: nicknames,
          serverAddress: serverAddress,
          userAvatar: userAvatar,
          whitelist: initialWhitelist,
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
      sessionFactory: sessionFactory,
      userAvatar: userAvatar,
    );
    unawaited(_loadNicknameAndInitUserDir());
  }

  final SettingsManagementService _settingsManagementService;
  final ChatStorageGateway _chatStorageGateway;
  final SgtpConnectionService _sgtpConnection;
  final DirectRoomGateway _directRoomGateway;
  final KeyPackagePublisher _keyPackagePublisher;
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
  List<WhitelistEntry> _whitelist;
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
    List<WhitelistEntry> whitelistEntries,
  ) {
    _accountId = accountId;
    _config = newConfig;
    _whitelist = List.from(whitelistEntries);
    _nicknames = {for (final e in whitelistEntries) e.hexKey: e.name};
    _serverAddress = newServer;
    _userAvatar = null;
    _nickname = '';
    _username = '';
    _contactProfiles = {};
    _friendStates = {};
    _connectionError = null;

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
    return _userDirCoordinator.registerSelf(
      _buildUserDirSession(),
      force: true,
    );
  }

  // ── Intent: Whitelist changed ───────────────────────────────────────────

  void onWhitelistChanged(List<WhitelistEntry> entries) {
    final old = List<WhitelistEntry>.from(_whitelist);
    _whitelist = entries;
    _nicknames = {for (final e in entries) e.hexKey: e.name};
    _config = _config.copyWith(
      whitelist: entries.map((e) => e.hexKey).toSet(),
    );
    _roomsBloc.add(RoomsUpdateWhitelist(
      entries.map((e) => e.hexKey).toSet(),
    ));
    _roomsBloc.add(RoomsUpdateNicknames(
      {for (final e in entries) e.hexKey: e.name},
    ));
    _pushContactAvatarsToRooms();
    _buildState();
    unawaited(_syncWhitelistWithUserDir(old, entries));
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
      whitelist: List.unmodifiable(_whitelist),
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
  }

  void _pushContactAvatarsToRooms() {
    _roomsBloc.add(
      RoomsUpdateContactAvatars(
        _userDirSupport.buildContactAvatarsByPubkey(
          whitelist: _whitelist,
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
      whitelist: _whitelist,
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
    _whitelist = List<WhitelistEntry>.from(coordState.whitelist);
    _nicknames = Map<String, String>.from(coordState.nicknames);
    _config = _config.copyWith(
      whitelist: _whitelist.map((entry) => entry.hexKey).toSet(),
    );
    _roomsBloc
        .add(RoomsUpdateWhitelist(_whitelist.map((e) => e.hexKey).toSet()));
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
    await _userDirCoordinator.registerSelf(_buildUserDirSession(),
        force: force);
  }

  Future<void> _syncWhitelistWithUserDir(
    List<WhitelistEntry> previousWhitelist,
    List<WhitelistEntry> nextWhitelist,
  ) async {
    await _ensureShellConnection();
    await _userDirCoordinator.applyWhitelistChanges(
      session: _buildUserDirSession(),
      previousWhitelist: previousWhitelist,
      nextWhitelist: nextWhitelist,
      nextNicknames: {for (final e in nextWhitelist) e.hexKey: e.name},
    );
  }

  Future<void> _ensureShellConnection() async {
    _connectionError = null;
    try {
      await _sgtpConnection.configure(_config);
      await _sgtpConnection.ensureConnected();
      await _keyPackagePublisher.ensureUploaded(
        _config.copyWith(accountId: _accountId),
      );
    } catch (e) {
      _connectionError = '$e';
      _buildState();
      rethrow;
    }
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
    unawaited(_userDirCoordinator.dispose());
    _roomsBloc.close();
    unawaited(_sgtpConnection.disconnect());
    await super.close();
  }
}
