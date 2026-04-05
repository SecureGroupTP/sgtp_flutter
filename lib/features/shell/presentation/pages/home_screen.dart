import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:sgtp_flutter/core/app_theme.dart';
import 'package:sgtp_flutter/core/di/injector.dart';
import 'package:sgtp_flutter/features/messaging/application/blocs/rooms/rooms_bloc.dart';
import 'package:sgtp_flutter/features/messaging/application/blocs/rooms/rooms_event.dart';
import 'package:sgtp_flutter/features/messaging/domain/entities/sgtp_config.dart';
import 'package:sgtp_flutter/features/shell/presentation/widgets/app_nav_bar.dart';
import 'package:sgtp_flutter/features/contacts/presentation/pages/contacts_screen.dart';
import 'package:sgtp_flutter/features/setup/presentation/pages/onboarding_page.dart';
import 'package:sgtp_flutter/features/messaging/presentation/pages/rooms_page.dart';
import 'package:sgtp_flutter/features/settings/presentation/pages/settings_screen.dart';
import 'package:sgtp_flutter/features/shell/application/models/app_startup_result.dart';
import 'package:sgtp_flutter/features/shell/application/models/home_userdir_models.dart';
import 'package:sgtp_flutter/features/shell/application/services/app_startup_service.dart';
import 'package:sgtp_flutter/features/shell/application/services/home_persistence_service.dart';
import 'package:sgtp_flutter/features/shell/application/services/home_userdir_coordinator.dart';
import 'package:sgtp_flutter/features/shell/application/services/home_userdir_support_service.dart';
import 'package:sgtp_flutter/features/messaging/domain/repositories/chat_storage_gateway.dart';
import 'package:sgtp_flutter/features/messaging/domain/repositories/i_sgtp_session.dart';
import 'package:sgtp_flutter/features/settings/application/services/settings_management_service.dart';
import 'package:sgtp_flutter/features/setup/domain/entities/contact_directory_models.dart';

/// Main screen shown after initial setup.
/// Three-tab bottom navigation: Rooms | Contacts | Settings.
class HomeScreen extends StatefulWidget {
  final String accountId;
  final SgtpConfig initialConfig;
  final Map<String, String> nicknames;
  final String serverAddress;
  final Uint8List? userAvatar;
  final List<WhitelistEntry> initialWhitelist;

  const HomeScreen({
    super.key,
    required this.accountId,
    required this.initialConfig,
    required this.nicknames,
    required this.serverAddress,
    this.userAvatar,
    this.initialWhitelist = const [],
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _currentIndex = 0;
  late final HomePersistenceService _homePersistence;
  late final HomeUserDirSupportService _userDirSupport;
  late final HomeUserDirCoordinator _userDirCoordinator;
  late RoomsBloc _roomsBloc;
  final _roomsPageKey = GlobalKey<RoomsPageState>();
  late Map<String, String> _nicknames;
  late String _serverAddress;
  late SgtpConfig _config;
  Uint8List? _userAvatar;
  late List<WhitelistEntry> _whitelist;
  late String _accountId;

  Map<String, ContactProfile> _contactProfiles = {};
  Map<String, FriendStateRecord> _friendStates = {};
  String _nickname = '';
  String _username = '';

  @override
  void initState() {
    super.initState();
    _homePersistence = context.read<HomePersistenceService>();
    _userDirSupport = context.read<HomeUserDirSupportService>();
    _accountId = widget.accountId;
    _config = widget.initialConfig;
    _nicknames = widget.nicknames;
    _serverAddress = widget.serverAddress;
    _userAvatar = widget.userAvatar;
    _whitelist = List.from(widget.initialWhitelist);
    _userDirCoordinator = context.read<AppDependencies>().homeUserDirCoordinatorFactory(
      onDirectMessageReady: (
        roomUUIDHex,
        peerHex,
        displayName,
        avatarBytes,
      ) {
        return _upsertDmChat(
          roomUUIDHex: roomUUIDHex,
          peerHex: peerHex,
          displayName: displayName,
          avatarBytes: avatarBytes,
        );
      },
      onStateChanged: _applyCoordinatorState,
    );
    _roomsBloc = RoomsBloc(
      accountId: _accountId,
      baseConfig: _config,
      nicknames: _nicknames,
      settingsRepository: context.read<SettingsManagementService>(),
      chatStorage: context.read<ChatStorageGateway>(),
      serverAddress: _serverAddress,
      sessionFactory: context.read<SgtpSessionFactory>(),
      userAvatar: _userAvatar,
    );
    unawaited(_loadNicknameAndInitUserDir());
  }

  Future<void> _loadNicknameAndInitUserDir() async {
    if (_accountId.trim().isNotEmpty) {
      final accountState = await _homePersistence.loadAccountState(_accountId);
      _nickname = accountState.nickname;
      final rawUsername = accountState.username;
      final normalized = _userDirSupport.normalizeUsername(rawUsername);
      _username = normalized ?? '';
      if ((rawUsername.trim()) != _username) {
        await _homePersistence.saveUsername(_accountId, _username);
      }
    }
    await _userDirCoordinator.start(_buildUserDirSession());
  }

  @override
  void dispose() {
    unawaited(_userDirCoordinator.dispose());
    _roomsBloc.close();
    super.dispose();
  }

  void _onConfigChanged(
    String accountId,
    SgtpConfig newConfig,
    Map<String, String> newNicknames,
    String newServer,
    List<WhitelistEntry> whitelistEntries,
  ) {
    setState(() {
      _accountId = accountId;
      _config = newConfig;
      _whitelist = List.from(whitelistEntries);
      _nicknames = {for (final e in whitelistEntries) e.hexKey: e.name};
      _serverAddress = newServer;
      _contactProfiles = {};
      _friendStates = {};
    });
    unawaited(_userDirCoordinator.dispose());
    _roomsBloc.close();
    _roomsBloc = RoomsBloc(
      accountId: _accountId,
      baseConfig: newConfig,
      nicknames: _nicknames,
      settingsRepository: context.read<SettingsManagementService>(),
      chatStorage: context.read<ChatStorageGateway>(),
      serverAddress: newServer,
      userAvatar: _userAvatar,
    );
    _pushContactAvatarsToRooms();
    unawaited(_loadNicknameAndInitUserDir());
  }

  void _onNicknameChanged(String nickname) {
    if (_nickname == nickname) return;
    _nickname = nickname;
    unawaited(_userDirCoordinator.registerSelf(_buildUserDirSession(), force: true));
  }

  Future<String?> _onUsernameChanged(String username) async {
    final next = _userDirSupport.normalizeUsername(username) ?? '';
    if (_username == next) return null;
    _username = next;
    return _userDirCoordinator.registerSelf(_buildUserDirSession(), force: true);
  }

  void _onWhitelistChanged(List<WhitelistEntry> entries) {
    final old = List<WhitelistEntry>.from(_whitelist);
    setState(() {
      _whitelist = entries;
      _nicknames = {for (final e in entries) e.hexKey: e.name};
      _config = _config.copyWith(
        whitelist: entries.map((e) => e.hexKey).toSet(),
      );
    });
    // Hot-push to all already-running rooms — no reconnect, no data loss.
    _roomsBloc.add(RoomsUpdateWhitelist(
      entries.map((e) => e.hexKey).toSet(),
    ));
    _roomsBloc.add(RoomsUpdateNicknames(
      {for (final e in entries) e.hexKey: e.name},
    ));
    _pushContactAvatarsToRooms();
    unawaited(
      _userDirCoordinator.applyWhitelistChanges(
        session: _buildUserDirSession(),
        previousWhitelist: old,
        nextWhitelist: entries,
        nextNicknames: {for (final e in entries) e.hexKey: e.name},
      ),
    );
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

  Future<void> _upsertDmChat({
    required String roomUUIDHex,
    required String peerHex,
    required String displayName,
    required Uint8List? avatarBytes,
  }) async {
    final room = roomUUIDHex.toLowerCase().replaceAll('-', '');
    if (room.length != 32) return;
    await _homePersistence.upsertDirectMessageChat(
      accountId: _accountId,
      roomUUID: room,
      serverAddress: _serverAddress,
      displayName: displayName,
      avatarBytes: avatarBytes,
    );
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
    );
  }

  void _applyCoordinatorState(HomeUserDirState state) {
    if (!mounted) return;
    final nextWhitelist = List<WhitelistEntry>.from(state.whitelist);
    final nextNicknames = Map<String, String>.from(state.nicknames);
    setState(() {
      _contactProfiles = Map<String, ContactProfile>.from(state.contactProfiles);
      _friendStates = Map<String, FriendStateRecord>.from(state.friendStates);
      _whitelist = nextWhitelist;
      _nicknames = nextNicknames;
      _config = _config.copyWith(
        whitelist: nextWhitelist.map((entry) => entry.hexKey).toSet(),
      );
    });
    _roomsBloc.add(RoomsUpdateWhitelist(_whitelist.map((e) => e.hexKey).toSet()));
    _roomsBloc.add(RoomsUpdateNicknames(_nicknames));
    _pushContactAvatarsToRooms();
  }

  Future<void> _refreshContactsFromServer() {
    return _userDirCoordinator.refresh(_buildUserDirSession());
  }

  void _showAddSheet() {
    _roomsPageKey.currentState?.showAddSheet();
  }

  void _onUserAvatarChanged(Uint8List? avatar) {
    setState(() => _userAvatar = avatar);
    _roomsBloc.setUserAvatar(avatar);
    unawaited(
      _userDirCoordinator.registerSelf(_buildUserDirSession(), force: true),
    );
  }

  void _onAllDataDeleted() {
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const AppStartScreen()),
      (_) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    return BlocProvider.value(
      value: _roomsBloc,
      child: Scaffold(
        extendBody: true,
        body: IndexedStack(
          index: _currentIndex,
          children: [
            // 0 — Rooms
            RoomsPage(
              key: _roomsPageKey,
              accountId: _accountId,
              serverAddress: _serverAddress,
            ),
            // 1 — Contacts
            ContactsScreen(
              accountId: _accountId,
              serverNodeId: _config.nodeId,
              initialEntries: _whitelist,
              onEntriesChanged: _onWhitelistChanged,
              contactProfiles: _contactProfiles,
              friendStates: _friendStates,
              onFriendRespond: (peerHex, accept) async {
                return _userDirCoordinator.respondToFriend(
                  session: _buildUserDirSession(),
                  peerHex: peerHex,
                  accept: accept,
                );
              },
              onOpenDm: (roomUUIDHex) {
                _roomsBloc.add(RoomsJoinRoom(
                  roomUUIDHex,
                  serverAddress: _serverAddress,
                ));
              },
            ),
            // 2 — Settings
            SettingsScreen(
              initialConfig: _config,
              initialNicknames: _nicknames,
              onConfigChanged: _onConfigChanged,
              onUserAvatarChanged: _onUserAvatarChanged,
              onNicknameChanged: _onNicknameChanged,
              onUsernameChanged: _onUsernameChanged,
              onAllDataDeleted: _onAllDataDeleted,
              currentUserAvatar: _userAvatar,
            ),
          ],
        ),
        floatingActionButton:
            _currentIndex == 0 ? _HomeFab(onPressed: _showAddSheet) : null,
        bottomNavigationBar: AppNavBar(
          selectedIndex: _currentIndex,
          onTap: (i) {
            setState(() => _currentIndex = i);
            if (i == 1) {
              unawaited(_refreshContactsFromServer());
            }
          },
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// FAB
// ─────────────────────────────────────────────────────────────────────────────

class _HomeFab extends StatelessWidget {
  final VoidCallback onPressed;
  const _HomeFab({required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: Colors.white.withAlpha(38), // rgba(255,255,255,0.15)
            blurRadius: 24,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: FloatingActionButton(
        onPressed: onPressed,
        tooltip: 'Add room',
        backgroundColor: AppColors.accent,
        foregroundColor: Colors.black,
        elevation: 0,
        highlightElevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        child: const Icon(Icons.add, size: 32),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Startup screen
// ─────────────────────────────────────────────────────────────────────────────

/// Loading screen that decides where to navigate on startup.
class AppStartScreen extends StatefulWidget {
  const AppStartScreen({super.key});

  @override
  State<AppStartScreen> createState() => _AppStartScreenState();
}

class _AppStartScreenState extends State<AppStartScreen> {
  @override
  void initState() {
    super.initState();
    _resolveStartup();
  }

  Future<void> _resolveStartup() async {
    final startup = context.read<AppStartupService>();
    final result = await startup.resolve();
    if (!mounted) return;

    switch (result.action) {
      case AppStartupAction.showOnboarding:
        final completed = await Navigator.of(context).push<bool>(
          MaterialPageRoute(builder: (_) => const OnboardingPage()),
        );
        if (completed == true && mounted) {
          await _resolveStartup();
        }
        break;
      case AppStartupAction.openHome:
        final data = result.homeLaunchData!;
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (_) => HomeScreen(
              accountId: data.accountId,
              initialConfig: data.config,
              nicknames: data.nicknames,
              serverAddress: data.serverAddress,
              userAvatar: data.userAvatar,
              initialWhitelist: data.initialWhitelist,
            ),
          ),
        );
        break;
      case AppStartupAction.retry:
        Future.delayed(const Duration(milliseconds: 500), _resolveStartup);
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(child: CircularProgressIndicator()),
    );
  }
}
