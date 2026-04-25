import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:sgtp_flutter/core/app/app_session_controller.dart';
import 'package:sgtp_flutter/core/app_theme.dart';
import 'package:sgtp_flutter/core/di/injector.dart';
import 'package:sgtp_flutter/core/network/sgtp_connection_service.dart';
import 'package:sgtp_flutter/features/messaging/domain/entities/direct_room_binding.dart';
import 'package:sgtp_flutter/features/messaging/domain/entities/sgtp_config.dart';
import 'package:sgtp_flutter/features/messaging/application/services/media_storage_service.dart';
import 'package:sgtp_flutter/features/messaging/application/services/message_notification_service.dart';
import 'package:sgtp_flutter/features/notifications/application/services/notification_host_service.dart';
import 'package:sgtp_flutter/features/notifications/application/services/push_notification_service.dart';
import 'package:sgtp_flutter/features/messaging/domain/repositories/chat_storage_gateway.dart';
import 'package:sgtp_flutter/features/messaging/domain/repositories/direct_room_gateway.dart';
import 'package:sgtp_flutter/features/messaging/domain/repositories/i_sgtp_session.dart';
import 'package:sgtp_flutter/features/messaging/domain/repositories/key_package_publisher.dart';
import 'package:sgtp_flutter/features/shell/presentation/widgets/app_nav_bar.dart';
import 'package:sgtp_flutter/features/contacts/presentation/pages/contacts_page.dart';
import 'package:sgtp_flutter/features/setup/presentation/pages/onboarding_page.dart';
import 'package:sgtp_flutter/features/messaging/presentation/pages/rooms_page.dart';
import 'package:sgtp_flutter/features/settings/presentation/pages/settings_page.dart';
import 'package:sgtp_flutter/features/shell/application/models/app_startup_result.dart';
import 'package:sgtp_flutter/features/shell/application/services/app_startup_service.dart';
import 'package:sgtp_flutter/features/shell/presentation/pages/local_encryption_unlock_page.dart';
import 'package:sgtp_flutter/features/shell/application/viewmodels/home_cubit.dart';
import 'package:sgtp_flutter/features/shell/application/viewmodels/home_view_state.dart';
import 'package:sgtp_flutter/features/settings/application/services/settings_management_service.dart';
import 'package:sgtp_flutter/features/shell/application/services/home_persistence_service.dart';
import 'package:sgtp_flutter/features/shell/application/services/home_userdir_support_service.dart';
import 'package:sgtp_flutter/features/setup/domain/entities/contact_directory_models.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Page — creates HomeCubit, provides it to the Screen
// ─────────────────────────────────────────────────────────────────────────────

class HomeScreen extends StatefulWidget {
  final String accountId;
  final SgtpConfig initialConfig;
  final Map<String, String> nicknames;
  final String serverAddress;
  final Uint8List? userAvatar;
  final List<ContactEntry> initialContacts;

  const HomeScreen({
    super.key,
    required this.accountId,
    required this.initialConfig,
    required this.nicknames,
    required this.serverAddress,
    this.userAvatar,
    this.initialContacts = const [],
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late final HomeCubit _homeCubit;

  @override
  void initState() {
    super.initState();
    final deps = context.read<AppDependencies>();
    _homeCubit = HomeCubit(
      accountId: widget.accountId,
      initialConfig: widget.initialConfig,
      nicknames: widget.nicknames,
      serverAddress: widget.serverAddress,
      userAvatar: widget.userAvatar,
      initialContacts: widget.initialContacts,
      settingsManagementService: context.read<SettingsManagementService>(),
      chatStorageGateway: context.read<ChatStorageGateway>(),
      sgtpConnectionService: context.read<SgtpConnectionService>(),
      directRoomGateway: context.read<DirectRoomGateway>(),
      keyPackagePublisher: context.read<KeyPackagePublisher>(),
      mediaStorageService: context.read<MessagingMediaStorageService>(),
      messageNotificationService: context.read<MessageNotificationService>(),
      notificationHostService: context.read<NotificationHostService>(),
      pushNotificationService: context.read<PushNotificationService>(),
      sessionFactory: context.read<SgtpSessionFactory>(),
      homePersistenceService: context.read<HomePersistenceService>(),
      homeUserDirSupportService: context.read<HomeUserDirSupportService>(),
      homeUserDirCoordinatorFactory: deps.homeUserDirCoordinatorFactory,
    );
  }

  @override
  void dispose() {
    _homeCubit.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return BlocProvider.value(
      value: _homeCubit,
      child: const _HomeScreenView(),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Screen — reads state from HomeCubit, sends intents back
// ─────────────────────────────────────────────────────────────────────────────

class _HomeScreenView extends StatefulWidget {
  const _HomeScreenView();

  @override
  State<_HomeScreenView> createState() => _HomeScreenViewState();
}

class _HomeScreenViewState extends State<_HomeScreenView> {
  final _roomsPageKey = GlobalKey<RoomsPageState>();
  late final AppSessionController _appSessionController;

  HomeCubit get _cubit => context.read<HomeCubit>();

  @override
  void initState() {
    super.initState();
    _appSessionController = _HomeAppSessionController(
      homeCubit: _cubit,
      roomsPageKey: _roomsPageKey,
    );
  }

  void _showAddSheet() {
    _roomsPageKey.currentState?.showAddSheet();
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
    return BlocBuilder<HomeCubit, HomeViewState>(
      builder: (context, state) {
        return RepositoryProvider<AppSessionController>.value(
          value: _appSessionController,
          child: BlocProvider.value(
            value: _cubit.roomsBloc,
            child: Scaffold(
              extendBody: true,
              body: IndexedStack(
                index: state.currentTabIndex,
                children: [
                  // 0 — Rooms
                  RoomsPage(
                    key: _roomsPageKey,
                    accountId: state.accountId,
                    serverAddress: state.serverAddress,
                  ),
                  // 1 — Contacts
                  ContactsPage(
                    accountId: state.accountId,
                    serverNodeId: state.config.nodeId,
                    myPubkeyHex: state.myPubkeyHex,
                    initialContacts: state.contacts,
                    contactProfiles: state.contactProfiles,
                    friendStates: state.friendStates,
                  ),
                  // 2 — Settings
                  SettingsPage(
                    initialConfig: state.config,
                    onAllDataDeleted: _onAllDataDeleted,
                    currentUserAvatar: state.userAvatar,
                  ),
                ],
              ),
              floatingActionButton: state.currentTabIndex == 0
                  ? _HomeFab(onPressed: _showAddSheet)
                  : null,
              bottomNavigationBar: AppNavBar(
                selectedIndex: state.currentTabIndex,
                onTap: (i) => _cubit.setTabIndex(i),
              ),
            ),
          ),
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// FAB
// ─────────────────────────────────────────────────────────────────────────────

class _HomeAppSessionController implements AppSessionController {
  _HomeAppSessionController({
    required HomeCubit homeCubit,
    required GlobalKey<RoomsPageState> roomsPageKey,
  }) : _homeCubit = homeCubit,
       _roomsPageKey = roomsPageKey;

  final HomeCubit _homeCubit;
  final GlobalKey<RoomsPageState> _roomsPageKey;

  @override
  void applyAccountConfig({
    required String accountId,
    required SgtpConfig config,
    required Map<String, String> nicknames,
    required String serverAddress,
    required List<ContactEntry> contactEntries,
  }) {
    _homeCubit.onConfigChanged(
      accountId,
      config,
      nicknames,
      serverAddress,
      contactEntries,
    );
  }

  @override
  void setCurrentUserAvatar(Uint8List? avatar) {
    _homeCubit.onUserAvatarChanged(avatar);
  }

  @override
  void setCurrentNickname(String nickname) {
    _homeCubit.onNicknameChanged(nickname);
  }

  @override
  Future<String?> setCurrentUsername(String username) {
    return _homeCubit.onUsernameChanged(username);
  }

  @override
  void setContactEntries(List<ContactEntry> entries) {
    _homeCubit.onContactsChanged(entries);
  }

  @override
  Future<bool> respondToFriend(String peerPubkeyHex, bool accept) {
    return _homeCubit.respondToFriend(peerPubkeyHex, accept);
  }

  @override
  Future<DirectRoomBinding?> openDirectMessage(String peerPubkeyHex) async {
    final binding = await _homeCubit.openDm(peerPubkeyHex);
    if (binding == null) return null;
    final roomsPage = _roomsPageKey.currentState;
    if (roomsPage != null) {
      roomsPage.openRoomByUuid(
        binding.roomId,
        serverAddress: _homeCubit.state.serverAddress,
        isDirectMessage: true,
        bootstrapDirectRoom: !binding.alreadyExisted,
        directPeerPublicKeyHex: peerPubkeyHex,
      );
    }
    return binding;
  }
}

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
            color: Colors.white.withAlpha(38),
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
        final completed = await Navigator.of(
          context,
        ).push<bool>(MaterialPageRoute(builder: (_) => const OnboardingPage()));
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
              initialContacts: data.initialContacts,
            ),
          ),
        );
        break;
      case AppStartupAction.unlockLocalEncryption:
        final unlocked = await Navigator.of(context).push<bool>(
          MaterialPageRoute(
            builder: (_) => LocalEncryptionUnlockPage(
              settings: context.read<SettingsManagementService>(),
              state: result.localEncryptionState!,
            ),
          ),
        );
        if (unlocked == true && mounted) {
          await _resolveStartup();
        }
        break;
      case AppStartupAction.retry:
        Future.delayed(const Duration(milliseconds: 500), _resolveStartup);
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(body: Center(child: CircularProgressIndicator()));
  }
}
