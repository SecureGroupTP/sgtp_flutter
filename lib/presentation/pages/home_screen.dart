import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../data/repositories/settings_repository.dart';
import '../../core/openssh_parser.dart';
import '../../core/crypto/ed25519_utils.dart';
import '../../data/sgtp_client.dart';
import '../blocs/rooms/rooms_bloc.dart';
import '../widgets/app_nav_bar.dart';
import 'rooms_page.dart';
import 'settings_screen.dart';

/// Main screen shown after initial setup.
/// Contains bottom navigation: Rooms | Settings.
class HomeScreen extends StatefulWidget {
  final SgtpConfig initialConfig;
  final Map<String, String> nicknames;
  final String serverAddress;
  final Uint8List? userAvatar;

  const HomeScreen({
    super.key,
    required this.initialConfig,
    required this.nicknames,
    required this.serverAddress,
    this.userAvatar,
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _currentIndex = 0;
  late RoomsBloc _roomsBloc;
  final _roomsPageKey = GlobalKey<RoomsPageState>();
  late Map<String, String> _nicknames;
  late String _serverAddress;
  late SgtpConfig _config;
  Uint8List? _userAvatar;

  @override
  void initState() {
    super.initState();
    _config        = widget.initialConfig;
    _nicknames     = widget.nicknames;
    _serverAddress = widget.serverAddress;
    _userAvatar    = widget.userAvatar;
    _roomsBloc = RoomsBloc(
      baseConfig:    _config,
      nicknames:     _nicknames,
      serverAddress: _serverAddress,
      userAvatar:    _userAvatar,
    );
  }

  @override
  void dispose() {
    _roomsBloc.close();
    super.dispose();
  }

  void _onConfigChanged(SgtpConfig newConfig, Map<String, String> newNicknames, String newServer) {
    setState(() {
      _config        = newConfig;
      _nicknames     = newNicknames;
      _serverAddress = newServer;
    });
    _roomsBloc.close();
    _roomsBloc = RoomsBloc(
      baseConfig:    newConfig,
      nicknames:     newNicknames,
      serverAddress: newServer,
      userAvatar:    _userAvatar,
    );
  }

  void _showAddSheet() {
    _roomsPageKey.currentState?.showAddSheet(context);
  }

  void _onUserAvatarChanged(Uint8List? avatar) {
    setState(() => _userAvatar = avatar);
    _roomsBloc.setUserAvatar(avatar);
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
            RoomsPage(key: _roomsPageKey),
            SettingsScreen(
              initialConfig:        _config,
              initialNicknames:     _nicknames,
              onConfigChanged:      _onConfigChanged,
              onUserAvatarChanged:  _onUserAvatarChanged,
              currentUserAvatar:    _userAvatar,
            ),
          ],
        ),
        floatingActionButton: _currentIndex == 0
            ? _HomeFab(onPressed: _showAddSheet)
            : null,
        bottomNavigationBar: AppNavBar(
          selectedIndex: _currentIndex,
          onTap: (i) => setState(() => _currentIndex = i),
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
    return FloatingActionButton(
      onPressed: onPressed,
      tooltip: 'Add room',
      backgroundColor: Colors.white,
      foregroundColor: Colors.black,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: const Icon(Icons.add, size: 32),
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
    _checkAndNavigate();
  }

  Future<void> _checkAndNavigate() async {
    final settings = SettingsRepository();
    final savedKey  = await settings.loadPrivateKey();
    final lastAddr  = await settings.getLastAddress();

    if (savedKey == null || lastAddr == null || lastAddr.isEmpty) {
      if (mounted) _goToSetup();
      return;
    }

    try {
      final parsed  = parseOpenSshPrivateKey(savedKey.bytes);
      final keyPair = makeKeyPair(parsed.seed, parsed.publicKey);

      final entries   = await settings.loadWhitelistEntries();
      final whitelist = entries.map((e) => e.hexKey).toSet();
      final nicknames = { for (final e in entries) e.hexKey: e.name };

      final userAvatar = await settings.loadUserAvatar();

      final config = SgtpConfig(
        serverAddr:      lastAddr,
        roomUUID:        Uint8List(16),
        identityKeyPair: keyPair,
        myPublicKey:     parsed.publicKey,
        whitelist:       whitelist,
      );

      if (mounted) {
        Navigator.of(context).pushReplacement(MaterialPageRoute(
          builder: (_) => HomeScreen(
            initialConfig: config,
            nicknames:     nicknames,
            serverAddress: lastAddr,
            userAvatar:    userAvatar,
          ),
        ));
      }
    } catch (_) {
      if (mounted) _goToSetup();
    }
  }

  void _goToSetup() {
    Navigator.of(context).pushReplacementNamed('/setup');
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(child: CircularProgressIndicator()),
    );
  }
}


