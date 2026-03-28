import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../data/repositories/settings_repository.dart';
import '../../core/openssh_parser.dart';
import '../../core/crypto/ed25519_utils.dart';
import '../../data/sgtp_client.dart';
import '../blocs/rooms/rooms_bloc.dart';
import 'rooms_page.dart';
import 'settings_screen.dart';

/// Main screen shown after initial setup.
/// Contains bottom navigation: Rooms | Settings.
class HomeScreen extends StatefulWidget {
  final SgtpConfig initialConfig;
  final Map<String, String> nicknames;
  final String serverAddress;

  const HomeScreen({
    super.key,
    required this.initialConfig,
    required this.nicknames,
    required this.serverAddress,
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _currentIndex = 0;
  late RoomsBloc _roomsBloc;
  late Map<String, String> _nicknames;
  late String _serverAddress;
  late SgtpConfig _config;

  @override
  void initState() {
    super.initState();
    _config        = widget.initialConfig;
    _nicknames     = widget.nicknames;
    _serverAddress = widget.serverAddress;
    _roomsBloc = RoomsBloc(
      baseConfig:    _config,
      nicknames:     _nicknames,
      serverAddress: _serverAddress,
    );
  }

  @override
  void dispose() {
    _roomsBloc.close();
    super.dispose();
  }

  /// Called from SettingsScreen when connection parameters change.
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
    );
  }

  @override
  Widget build(BuildContext context) {
    return BlocProvider.value(
      value: _roomsBloc,
      child: Scaffold(
        body: IndexedStack(
          index: _currentIndex,
          children: [
            const RoomsPage(),
            SettingsScreen(
              initialConfig:    _config,
              initialNicknames: _nicknames,
              onConfigChanged:  _onConfigChanged,
            ),
          ],
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _currentIndex,
          onDestinationSelected: (i) => setState(() => _currentIndex = i),
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.meeting_room_outlined),
              selectedIcon: Icon(Icons.meeting_room),
              label: 'Rooms',
            ),
            NavigationDestination(
              icon: Icon(Icons.settings_outlined),
              selectedIcon: Icon(Icons.settings),
              label: 'Settings',
            ),
          ],
        ),
      ),
    );
  }
}

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
      // First run — show setup
      if (mounted) _goToSetup();
      return;
    }

    // Try to restore saved config
    try {
      final parsed  = parseOpenSshPrivateKey(savedKey.bytes);
      final keyPair = makeKeyPair(parsed.seed, parsed.publicKey);

      final savedWl  = await settings.loadWhitelist();
      final wlBytes  = savedWl?.bytesList ?? <Uint8List>[];
      final wlPaths  = savedWl?.paths ?? <String>[];
      final whitelist = wlBytes.map((b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join()).toSet();
      final nicknames = _buildNicknames(wlBytes, wlPaths);

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
            initialConfig: config, nicknames: nicknames, serverAddress: lastAddr,
          ),
        ));
      }
    } catch (_) {
      // Saved key is invalid — back to setup
      if (mounted) _goToSetup();
    }
  }

  void _goToSetup() {
    Navigator.of(context).pushReplacementNamed('/setup');
  }

  Map<String, String> _buildNicknames(List<Uint8List> bytesList, List<String> paths) {
    final result = <String, String>{};
    for (var i = 0; i < bytesList.length; i++) {
      final hex = bytesList[i].map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      var name = paths[i];
      if (name.toLowerCase().endsWith('.pub')) name = name.substring(0, name.length - 4);
      result[hex] = name;
    }
    return result;
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(child: CircularProgressIndicator()),
    );
  }
}
