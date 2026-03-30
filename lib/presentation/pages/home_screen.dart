import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/app_theme.dart';
import '../../data/repositories/settings_repository.dart';
import '../../core/openssh_parser.dart';
import '../../core/crypto/ed25519_utils.dart';
import '../../data/sgtp_client.dart';
import '../blocs/rooms/rooms_bloc.dart';
import '../blocs/rooms/rooms_event.dart';
import '../widgets/app_nav_bar.dart';
import 'contacts_screen.dart';
import 'rooms_page.dart';
import 'settings_screen.dart';

/// Main screen shown after initial setup.
/// Three-tab bottom navigation: Rooms | Contacts | Settings.
class HomeScreen extends StatefulWidget {
  final SgtpConfig initialConfig;
  final Map<String, String> nicknames;
  final String serverAddress;
  final Uint8List? userAvatar;
  final List<WhitelistEntry> initialWhitelist;

  const HomeScreen({
    super.key,
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
  late RoomsBloc _roomsBloc;
  final _roomsPageKey = GlobalKey<RoomsPageState>();
  late Map<String, String> _nicknames;
  late String _serverAddress;
  late SgtpConfig _config;
  Uint8List? _userAvatar;
  late List<WhitelistEntry> _whitelist;

  @override
  void initState() {
    super.initState();
    _config = widget.initialConfig;
    _nicknames = widget.nicknames;
    _serverAddress = widget.serverAddress;
    _userAvatar = widget.userAvatar;
    _whitelist = List.from(widget.initialWhitelist);
    _roomsBloc = RoomsBloc(
      baseConfig: _config,
      nicknames: _nicknames,
      serverAddress: _serverAddress,
      userAvatar: _userAvatar,
    );
  }

  @override
  void dispose() {
    _roomsBloc.close();
    super.dispose();
  }

  void _onConfigChanged(SgtpConfig newConfig, Map<String, String> newNicknames,
      String newServer) {
    setState(() {
      _config = newConfig;
      _nicknames = newNicknames;
      _serverAddress = newServer;
    });
    _roomsBloc.close();
    _roomsBloc = RoomsBloc(
      baseConfig: newConfig,
      nicknames: newNicknames,
      serverAddress: newServer,
      userAvatar: _userAvatar,
    );
  }

  void _onWhitelistChanged(List<WhitelistEntry> entries) {
    setState(() {
      _whitelist = entries;
      _nicknames = {for (final e in entries) e.hexKey: e.name};
      // Keep stored config in sync so future rooms use the new whitelist.
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
  }

  void _showAddSheet() {
    _roomsPageKey.currentState?.showAddSheet();
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
            // 0 — Rooms
            RoomsPage(key: _roomsPageKey),
            // 1 — Contacts
            ContactsScreen(
              initialEntries: _whitelist,
              onEntriesChanged: _onWhitelistChanged,
            ),
            // 2 — Settings
            SettingsScreen(
              initialConfig: _config,
              initialNicknames: _nicknames,
              onConfigChanged: _onConfigChanged,
              onUserAvatarChanged: _onUserAvatarChanged,
              currentUserAvatar: _userAvatar,
            ),
          ],
        ),
        floatingActionButton:
            _currentIndex == 0 ? _HomeFab(onPressed: _showAddSheet) : null,
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
    _checkAndNavigate();
  }

  Future<void> _checkAndNavigate() async {
    final settings = SettingsRepository();
    var savedKey = await settings.loadPrivateKey();
    final lastAddr = await settings.getLastAddress() ?? '';

    // First launch: auto-generate an Ed25519 identity key silently.
    if (savedKey == null) {
      savedKey = await _autoGenerateKey(settings);
    }

    // If key generation somehow failed, we still land on HomeScreen —
    // the user will see an empty state and can configure via Settings.
    if (savedKey == null) return;

    try {
      final parsed = parseOpenSshPrivateKey(savedKey.bytes);
      final keyPair = makeKeyPair(parsed.seed, parsed.publicKey);
      final mediaSettings = await settings.loadMediaTransferSettings();

      final entries = await settings.loadWhitelistEntries();
      final whitelist = entries.map((e) => e.hexKey).toSet();
      final nicknames = {for (final e in entries) e.hexKey: e.name};
      final userAvatar = await settings.loadUserAvatar();

      final config = SgtpConfig(
        serverAddr: lastAddr.isEmpty ? 'localhost:7777' : lastAddr,
        roomUUID: Uint8List(16),
        identityKeyPair: keyPair,
        myPublicKey: parsed.publicKey,
        whitelist: whitelist,
        mediaChunkSizeBytes: mediaSettings.mediaChunkSizeBytes,
      );

      if (mounted) {
        Navigator.of(context).pushReplacement(MaterialPageRoute(
          builder: (_) => HomeScreen(
            initialConfig: config,
            nicknames: nicknames,
            serverAddress: lastAddr,
            userAvatar: userAvatar,
            initialWhitelist: entries,
          ),
        ));
      }
    } catch (_) {
      // Corrupted key — clear it and try again next launch.
      await settings.clearPrivateKey();
      if (mounted) _checkAndNavigate();
    }
  }

  /// Silently generates a fresh Ed25519 key on first launch.
  Future<({Uint8List bytes, String name})?> _autoGenerateKey(
      SettingsRepository settings) async {
    try {
      final algorithm = Ed25519();
      final keyPair = await algorithm.newKeyPair();
      final pubKey = await keyPair.extractPublicKey();
      final privBytes = await keyPair.extractPrivateKeyBytes();
      final pubBytes = Uint8List.fromList(pubKey.bytes);
      final opensshBytes = _encodeOpenSshPrivateKey(privBytes, pubBytes);
      await settings.savePrivateKey(opensshBytes, 'identity');
      return (bytes: opensshBytes, name: 'identity');
    } catch (_) {
      return null;
    }
  }

  Uint8List _encodeOpenSshPrivateKey(List<int> seed, Uint8List pubKey) {
    const magic = 'openssh-key-v1\x00';
    final header = _sshStr('none') + _sshStr('none') + _sshStr('') + _u32(1);
    final pubBlock = _sshStr('ssh-ed25519') + _sshStr(pubKey);
    final pubWrapped = _sshStr(pubBlock);
    final rng = Random.secure();
    final check = rng.nextInt(0xFFFFFFFF);
    final fullPriv = Uint8List(64)
      ..setAll(0, seed)
      ..setAll(32, pubKey);
    final privBlock = _u32(check) +
        _u32(check) +
        _sshStr('ssh-ed25519') +
        _sshStr(pubKey) +
        _sshStr(fullPriv) +
        _sshStr('sgtp-generated');
    final padded = List<int>.from(privBlock);
    int pad = 1;
    while (padded.length % 8 != 0) padded.add(pad++);
    final body = magic.codeUnits + header + pubWrapped + _sshStr(padded);
    final b64 = base64Encode(body);
    final sb = StringBuffer('-----BEGIN OPENSSH PRIVATE KEY-----\n');
    for (var i = 0; i < b64.length; i += 70) {
      sb.writeln(b64.substring(i, (i + 70).clamp(0, b64.length)));
    }
    sb.write('-----END OPENSSH PRIVATE KEY-----');
    return Uint8List.fromList(sb.toString().codeUnits);
  }

  List<int> _sshStr(dynamic d) {
    final b = d is String ? d.codeUnits : (d as List<int>);
    return _u32(b.length) + b;
  }

  List<int> _u32(int v) =>
      [(v >> 24) & 0xFF, (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF];

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(child: CircularProgressIndicator()),
    );
  }
}
