import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/app_theme.dart';
import '../../data/repositories/settings_repository.dart';
import '../../data/userdir_client.dart';
import '../../core/openssh_parser.dart';
import '../../core/crypto/ed25519_utils.dart';
import '../../core/sgtp_transport.dart';
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
  late RoomsBloc _roomsBloc;
  final _roomsPageKey = GlobalKey<RoomsPageState>();
  late Map<String, String> _nicknames;
  late String _serverAddress;
  late SgtpConfig _config;
  Uint8List? _userAvatar;
  late List<WhitelistEntry> _whitelist;
  late String _accountId;

  UserDirClient? _userDirClient;
  StreamSubscription<UserDirMeta>? _userDirSub;
  Map<String, ContactProfile> _contactProfiles = {};
  Future<void> _notifyQueue = Future.value();
  String _nickname = '';
  String _username = '';

  @override
  void initState() {
    super.initState();
    _accountId = widget.accountId;
    _config = widget.initialConfig;
    _nicknames = widget.nicknames;
    _serverAddress = widget.serverAddress;
    _userAvatar = widget.userAvatar;
    _whitelist = List.from(widget.initialWhitelist);
    _roomsBloc = RoomsBloc(
      accountId: _accountId,
      baseConfig: _config,
      nicknames: _nicknames,
      serverAddress: _serverAddress,
      userAvatar: _userAvatar,
    );
    unawaited(_loadNicknameAndInitUserDir());
  }

  Future<void> _loadNicknameAndInitUserDir() async {
    if (_accountId.trim().isNotEmpty) {
      final repo = SettingsRepository();
      _nickname = await repo.loadUserNicknameForNode(_accountId);
      _username = await repo.loadUserUsernameForNode(_accountId);
    }
    await _initUserDir();
  }

  @override
  void dispose() {
    _userDirSub?.cancel();
    _userDirClient?.close();
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
    });
    _roomsBloc.close();
    _roomsBloc = RoomsBloc(
      accountId: _accountId,
      baseConfig: newConfig,
      nicknames: _nicknames,
      serverAddress: newServer,
      userAvatar: _userAvatar,
    );
    unawaited(_loadNicknameAndInitUserDir());
  }

  void _onNicknameChanged(String nickname) {
    _nickname = nickname;
    unawaited(_registerSelf());
  }

  void _onUsernameChanged(String username) {
    _username = username;
    unawaited(_registerSelf());
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
    unawaited(_initUserDir());
  }

  /// Returns the @username: user-set value, or auto-derived from nickname,
  /// or falls back to pubkey prefix.
  String _buildUsername() {
    if (_username.isNotEmpty) return '@$_username';
    final sanitized = _nickname.replaceAll(RegExp(r'[^A-Za-z0-9_]'), '');
    if (sanitized.isNotEmpty) {
      return '@${sanitized.substring(0, sanitized.length.clamp(0, 32))}';
    }
    final pubHex = _config.myPublicKey
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    return '@${pubHex.substring(0, 16)}';
  }

  Future<void> _registerSelf() async {
    final client = _userDirClient;
    if (client == null) return;
    await client.register(
      username: _buildUsername(),
      fullname: _nickname,
      pubkey: _config.myPublicKey,
      avatarBytes: _userAvatar ?? Uint8List(0),
      identityKeyPair: _config.identityKeyPair,
    );
  }

  Future<void> _initUserDir() async {
    if (_accountId.trim().isEmpty || _whitelist.isEmpty) return;
    final parts = _serverAddress.split(':');
    if (parts.length < 2) return;
    final host = parts.sublist(0, parts.length - 1).join(':');
    final port = int.tryParse(parts.last);
    if (port == null) return;

    try {
      final client = UserDirClient(host: host, port: port);
      await client.connect();
      _userDirClient?.close();
      _userDirSub?.cancel();
      _userDirClient = client;

      // Register/update our own profile on the server
      await _registerSelf();

      final settings = SettingsRepository();
      final cached = await settings.loadAllContactProfiles(_accountId);

      // GET_META → compare sha256 → GET_PROFILE if stale
      for (final contact in _whitelist) {
        if (!mounted) break;
        final meta = await client.getMeta(contact.bytes);
        if (meta == null) continue;

        final cachedProfile = cached[contact.hexKey];
        if (cachedProfile == null ||
            cachedProfile.avatarSha256Hex != meta.avatarSha256Hex ||
            cachedProfile.avatarBytes == null) {
          // Avatar stale or missing — fetch full profile
          final profile = await client.getProfile(contact.bytes);
          if (profile == null) continue;
          final cp = ContactProfile(
            pubkeyHex: contact.hexKey,
            username: profile.username,
            fullname: profile.fullname,
            avatarBytes: profile.avatarBytes,
            avatarSha256Hex: profile.avatarSha256Hex,
            updatedAt: profile.updatedAt,
          );
          await settings.saveContactProfile(_accountId, cp);
          if (mounted) setState(() => _contactProfiles[contact.hexKey] = cp);
        } else if (cachedProfile.username != meta.username ||
            cachedProfile.fullname != meta.fullname) {
          // Name/username changed, avatar is same
          final cp = ContactProfile(
            pubkeyHex: contact.hexKey,
            username: meta.username,
            fullname: meta.fullname,
            avatarBytes: cachedProfile.avatarBytes,
            avatarSha256Hex: meta.avatarSha256Hex,
            updatedAt: meta.updatedAt,
          );
          await settings.saveContactProfile(_accountId, cp);
          if (mounted) setState(() => _contactProfiles[contact.hexKey] = cp);
        } else if (mounted) {
          setState(() => _contactProfiles[contact.hexKey] = cachedProfile);
        }
      }

      // Subscribe to all contacts for live NOTIFY
      await client.subscribe(_whitelist.map((e) => e.bytes).toList());

      // Queue NOTIFY handling serially to avoid concurrent GET_PROFILE calls
      _userDirSub = client.notifyStream.listen((meta) {
        _notifyQueue = _notifyQueue.then((_) => _handleNotify(meta, client));
      });
    } catch (_) {
      // Userdir unavailable — non-critical, proceed without profile sync
    }
  }

  Future<void> _handleNotify(UserDirMeta meta, UserDirClient client) async {
    if (!mounted) return;
    final settings = SettingsRepository();
    final cached =
        await settings.loadContactProfile(_accountId, meta.pubkeyHex);

    if (cached == null ||
        cached.avatarSha256Hex != meta.avatarSha256Hex ||
        cached.avatarBytes == null) {
      final profile = await client.getProfile(meta.pubkey);
      if (profile == null) return;
      final cp = ContactProfile(
        pubkeyHex: meta.pubkeyHex,
        username: profile.username,
        fullname: profile.fullname,
        avatarBytes: profile.avatarBytes,
        avatarSha256Hex: profile.avatarSha256Hex,
        updatedAt: profile.updatedAt,
      );
      await settings.saveContactProfile(_accountId, cp);
      if (mounted) setState(() => _contactProfiles[meta.pubkeyHex] = cp);
    } else {
      final cp = ContactProfile(
        pubkeyHex: meta.pubkeyHex,
        username: meta.username,
        fullname: meta.fullname,
        avatarBytes: cached.avatarBytes,
        avatarSha256Hex: meta.avatarSha256Hex,
        updatedAt: meta.updatedAt,
      );
      await settings.saveContactProfile(_accountId, cp);
      if (mounted) setState(() => _contactProfiles[meta.pubkeyHex] = cp);
    }
  }

  void _showAddSheet() {
    _roomsPageKey.currentState?.showAddSheet();
  }

  void _onUserAvatarChanged(Uint8List? avatar) {
    setState(() => _userAvatar = avatar);
    _roomsBloc.setUserAvatar(avatar);
    unawaited(_registerSelf());
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
            RoomsPage(key: _roomsPageKey, accountId: _accountId),
            // 1 — Contacts
            ContactsScreen(
              accountId: _accountId,
              initialEntries: _whitelist,
              onEntriesChanged: _onWhitelistChanged,
              contactProfiles: _contactProfiles,
            ),
            // 2 — Settings
            SettingsScreen(
              initialConfig: _config,
              initialNicknames: _nicknames,
              onConfigChanged: _onConfigChanged,
              onUserAvatarChanged: _onUserAvatarChanged,
              onNicknameChanged: _onNicknameChanged,
              onUsernameChanged: _onUsernameChanged,
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
    final lastAddr = await settings.getLastAddress() ?? '';
    final preferredNode = await settings.loadPreferredNode();
    final accountId = preferredNode?.id ?? (await settings.loadLastNodeId()) ?? '';
    final chatServer =
        preferredNode?.chatAddress ?? (lastAddr.isEmpty ? 'localhost:7777' : lastAddr);

    if (accountId.trim().isNotEmpty) {
      await settings.migrateLegacyAccountDataToNodeIfNeeded(accountId);
    }

    var savedKey = accountId.trim().isEmpty
        ? await settings.loadPrivateKey()
        : await settings.loadPrivateKeyForNode(accountId);

    // First launch (per-account): auto-generate an Ed25519 identity key silently.
    if (savedKey == null && accountId.trim().isNotEmpty) {
      savedKey = await _autoGenerateKey(settings, accountId);
    }

    // If key generation somehow failed, we still land on HomeScreen —
    // the user will see an empty state and can configure via Settings.
    if (savedKey == null) return;

    try {
      final parsed = parseOpenSshPrivateKey(savedKey.bytes);
      final keyPair = makeKeyPair(parsed.seed, parsed.publicKey);
      final mediaSettings = await settings.loadMediaTransferSettings();

      final entries = accountId.trim().isEmpty
          ? await settings.loadWhitelistEntries()
          : await settings.loadWhitelistEntriesForNode(accountId);
      final whitelist = entries.map((e) => e.hexKey).toSet();
      final nicknames = {for (final e in entries) e.hexKey: e.name};
      final userAvatar = accountId.trim().isEmpty
          ? await settings.loadUserAvatar()
          : await settings.loadUserAvatarForNode(accountId);

      final config = SgtpConfig(
        serverAddr: chatServer,
        roomUUID: Uint8List(16),
        identityKeyPair: keyPair,
        myPublicKey: parsed.publicKey,
        whitelist: whitelist,
        transport: preferredNode?.transport ?? SgtpTransportFamily.tcp,
        useTls: preferredNode?.useTls ?? false,
        nodeId: accountId.trim().isEmpty ? null : accountId,
        mediaChunkSizeBytes: mediaSettings.mediaChunkSizeBytes,
      );

      if (mounted) {
        Navigator.of(context).pushReplacement(MaterialPageRoute(
          builder: (_) => HomeScreen(
            accountId: accountId,
            initialConfig: config,
            nicknames: nicknames,
            serverAddress: chatServer,
            userAvatar: userAvatar,
            initialWhitelist: entries,
          ),
        ));
      }
    } catch (_) {
      // Corrupted key — clear it and try again next launch.
      if (accountId.trim().isNotEmpty) {
        await settings.clearPrivateKeyForNode(accountId);
      } else {
        await settings.clearPrivateKey();
      }
      if (mounted) _checkAndNavigate();
    }
  }

  /// Silently generates a fresh Ed25519 key on first launch.
  Future<({Uint8List bytes, String name})?> _autoGenerateKey(
      SettingsRepository settings, String accountId) async {
    try {
      final algorithm = Ed25519();
      final keyPair = await algorithm.newKeyPair();
      final pubKey = await keyPair.extractPublicKey();
      final privBytes = await keyPair.extractPrivateKeyBytes();
      final pubBytes = Uint8List.fromList(pubKey.bytes);
      final opensshBytes = _encodeOpenSshPrivateKey(privBytes, pubBytes);
      await settings.savePrivateKeyForNode(accountId, opensshBytes, 'identity');
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
