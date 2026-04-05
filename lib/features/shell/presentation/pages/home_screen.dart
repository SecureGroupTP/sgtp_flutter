import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:sgtp_flutter/core/app_logger.dart';
import 'package:sgtp_flutter/core/app_theme.dart';
import 'package:sgtp_flutter/core/sgtp_transport.dart';
import 'package:sgtp_flutter/core/openssh_parser.dart';
import 'package:sgtp_flutter/core/crypto/ed25519_utils.dart';
import 'package:sgtp_flutter/core/uuid_v7.dart';
import 'package:sgtp_flutter/features/messaging/application/blocs/rooms/rooms_bloc.dart';
import 'package:sgtp_flutter/features/messaging/application/blocs/rooms/rooms_event.dart';
import 'package:sgtp_flutter/features/shell/presentation/widgets/app_nav_bar.dart';
import 'package:sgtp_flutter/features/contacts/presentation/pages/contacts_screen.dart';
import 'package:sgtp_flutter/features/setup/presentation/pages/onboarding_page.dart';
import 'package:sgtp_flutter/features/messaging/presentation/pages/rooms_page.dart';
import 'package:sgtp_flutter/features/settings/presentation/pages/settings_screen.dart';
import 'package:sgtp_flutter/features/shell/application/services/shell_data_access.dart';
import 'package:sgtp_flutter/features/shell/application/models/shell_models.dart';
import 'package:sgtp_flutter/features/messaging/application/services/chat_storage_gateway.dart';

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
  StreamSubscription<UserDirFriendNotify>? _friendDirSub;
  Timer? _friendSyncTimer;
  Timer? _profileRegisterTimer;
  Map<String, ContactProfile> _contactProfiles = {};
  Map<String, FriendStateRecord> _friendStates = {};
  Set<String> _suppressedContacts = {};
  Future<void> _notifyQueue = Future.value();
  String _nickname = '';
  String _username = '';
  String _lastRegisteredFingerprint = '';

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
      final repo = context.read<SettingsRepository>();
      _nickname = await repo.loadUserNicknameForNode(_accountId);
      final rawUsername = await repo.loadUserUsernameForNode(_accountId);
      final normalized = _normalizeUsername(rawUsername);
      _username = normalized ?? '';
      if ((rawUsername.trim()) != _username) {
        await repo.saveUserUsernameForNode(_accountId, _username);
      }
      _friendStates = await repo.loadFriendStates(_accountId);
      _suppressedContacts = await repo.loadSuppressedContacts(_accountId);
    }
    await _initUserDir();
  }

  @override
  void dispose() {
    _userDirSub?.cancel();
    _friendDirSub?.cancel();
    _friendSyncTimer?.cancel();
    _profileRegisterTimer?.cancel();
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
      _contactProfiles = {};
      _friendStates = {};
      _suppressedContacts = {};
      _lastRegisteredFingerprint = '';
    });
    _roomsBloc.close();
    _roomsBloc = RoomsBloc(
      accountId: _accountId,
      baseConfig: newConfig,
      nicknames: _nicknames,
      serverAddress: newServer,
      userAvatar: _userAvatar,
    );
    _pushContactAvatarsToRooms();
    unawaited(_loadNicknameAndInitUserDir());
  }

  void _onNicknameChanged(String nickname) {
    if (_nickname == nickname) return;
    _nickname = nickname;
    unawaited(_registerSelf(force: true));
  }

  Future<String?> _onUsernameChanged(String username) async {
    final next = _normalizeUsername(username) ?? '';
    if (_username == next) return null;
    _username = next;
    return _registerSelf(force: true);
  }

  void _onWhitelistChanged(List<WhitelistEntry> entries) {
    final old = List<WhitelistEntry>.from(_whitelist);
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
    _pushContactAvatarsToRooms();
    unawaited(_initUserDir());
    final oldSet = old.map((e) => e.hexKey.toLowerCase()).toSet();
    final nextSet = entries.map((e) => e.hexKey.toLowerCase()).toSet();
    final removed = old.where((e) => !nextSet.contains(e.hexKey.toLowerCase()));
    final added =
        entries.where((e) => !oldSet.contains(e.hexKey.toLowerCase()));
    if (removed.isNotEmpty) {
      for (final entry in removed) {
        _suppressedContacts.add(entry.hexKey.toLowerCase());
        unawaited(_removeFriendOnServer(entry.hexKey));
      }
      unawaited(context.read<SettingsRepository>().saveSuppressedContacts(
        _accountId,
        _suppressedContacts,
      ));
    }
    for (final entry in added) {
      final hex = entry.hexKey.toLowerCase();
      if (_suppressedContacts.remove(hex)) {
        unawaited(context.read<SettingsRepository>().saveSuppressedContacts(
          _accountId,
          _suppressedContacts,
        ));
      }
      unawaited(_sendFriendRequestFor(entry));
    }
  }

  Future<void> _removeFriendOnServer(String peerHex) async {
    var client = _userDirClient;
    if (client == null || !client.isConnected) {
      await _initUserDir();
      client = _userDirClient;
    }
    if (client == null || !client.isConnected) return;
    try {
      final ok = await client.sendFriendDelete(
        myPubkey: _config.myPublicKey,
        peerPubkey: _hexToBytes32(peerHex),
        identityKeyPair: _config.identityKeyPair,
      );
      AppLogger.i(
        'FRIEND_DELETE ${ok ? 'sent' : 'failed'} peer=${peerHex.substring(0, 8)}',
        tag: 'UDIR',
      );
      if (ok) await _syncFriendStates(client);
    } catch (_) {}
  }

  Map<String, Uint8List> _buildContactAvatarsByPubkey() {
    final allowed = _whitelist.map((e) => e.hexKey).toSet();
    final out = <String, Uint8List>{};
    for (final entry in _contactProfiles.entries) {
      if (!allowed.contains(entry.key)) continue;
      final avatar = entry.value.avatarBytes;
      if (avatar != null && avatar.isNotEmpty) {
        out[entry.key] = avatar;
      }
    }
    return out;
  }

  void _pushContactAvatarsToRooms() {
    _roomsBloc.add(RoomsUpdateContactAvatars(_buildContactAvatarsByPubkey()));
  }

  /// Returns `@username` if the user has set one, otherwise null.
  String? _buildUsername() {
    final normalized = _normalizeUsername(_username);
    if (normalized != null && normalized.isNotEmpty) return '@$normalized';
    return null;
  }

  String? _normalizeUsername(String? raw) {
    if (raw == null) return null;
    final stripped = raw.trim().replaceFirst(RegExp(r'^@+'), '');
    final sanitized = stripped
        .replaceAll(RegExp(r'[^A-Za-z0-9_]'), '')
        .substring(
          0,
          stripped.replaceAll(RegExp(r'[^A-Za-z0-9_]'), '').length.clamp(0, 32),
        );
    if (sanitized.isEmpty) return null;
    return sanitized;
  }

  String _profileFingerprint() {
    final user = _buildUsername() ?? '';
    final avatarLen = _userAvatar?.length ?? 0;
    final pubHex = _config.myPublicKey
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    return '$pubHex|$user|$_nickname|$avatarLen';
  }

  Future<String?> _registerSelf({bool force = false}) async {
    final fp = _profileFingerprint();
    if (!force && _lastRegisteredFingerprint == fp) return null;
    Future<({bool ok, int? errorCode, String? errorMessage})> doRegister(
        UserDirClient client) {
      return client.registerWithResult(
        username: _buildUsername(),
        fullname: _nickname,
        pubkey: _config.myPublicKey,
        avatarBytes: _userAvatar ?? Uint8List(0),
        identityKeyPair: _config.identityKeyPair,
      );
    }

    var client = _userDirClient;
    if (client == null || !client.isConnected) {
      await _initUserDir();
      client = _userDirClient;
    }
    if (client == null || !client.isConnected) {
      // Do not show a hard validation error when the directory transport
      // is temporarily unavailable.
      return null;
    }

    var result = await doRegister(client);

    // Retry once after reconnect when server gave no explicit error details.
    if (!result.ok &&
        result.errorCode == null &&
        (result.errorMessage ?? '').trim().isEmpty) {
      await _initUserDir();
      final retry = _userDirClient;
      if (retry != null && retry.isConnected) {
        result = await doRegister(retry);
      }
    }

    if (result.ok) {
      _lastRegisteredFingerprint = fp;
      return null;
    }

    final code = result.errorCode;
    final msg = (result.errorMessage ?? '').trim();
    final lower = msg.toLowerCase();
    final isTaken = lower.contains('taken') ||
        lower.contains('exists') ||
        lower.contains('occupied') ||
        lower.contains('already');
    if (isTaken) return 'Username already taken';
    if (msg.isNotEmpty) return msg;
    if (code != null)
      return 'Username update failed (code: 0x${code.toRadixString(16)})';
    return 'Username update failed';
  }

  Future<void> _sendFriendRequestFor(WhitelistEntry entry) async {
    var client = _userDirClient;
    if (client == null || !client.isConnected) {
      await _initUserDir();
      client = _userDirClient;
    }
    if (client == null || !client.isConnected) return;
    final hex = entry.hexKey.toLowerCase();
    final existing = _friendStates[hex];
    if (existing != null &&
        (existing.statusEnum == FriendStatus.pendingOutgoing ||
            existing.statusEnum == FriendStatus.pendingIncoming)) {
      return;
    }
    try {
      final ok = await client.sendFriendRequest(
        myPubkey: _config.myPublicKey,
        peerPubkey: entry.bytes,
        identityKeyPair: _config.identityKeyPair,
      );
      AppLogger.i(
        'FRIEND_REQUEST ${ok ? 'sent' : 'failed'} peer=${hex.substring(0, 8)}',
        tag: 'UDIR',
      );
      await _syncFriendStates(client);
    } catch (_) {}
  }

  Uint8List _hexToBytes32(String hex) {
    final clean = hex.trim().toLowerCase();
    return Uint8List.fromList(List<int>.generate(
      32,
      (i) => int.parse(clean.substring(i * 2, i * 2 + 2), radix: 16),
    ));
  }

  Future<void> _ensureContactForPeer(String peerHex) async {
    final lower = peerHex.toLowerCase();
    if (_suppressedContacts.contains(lower)) return;
    if (_whitelist.any((e) => e.hexKey.toLowerCase() == lower)) return;

    ContactProfile? profile = _contactProfiles[lower];
    final client = _userDirClient;
    if (profile == null && client != null && client.isConnected) {
      try {
        final meta = await client.getMeta(_hexToBytes32(lower));
        if (meta != null) {
          profile = ContactProfile(
            pubkeyHex: lower,
            username: meta.username,
            fullname: meta.fullname,
            avatarBytes: null,
            avatarSha256Hex: meta.avatarSha256Hex,
            updatedAt: meta.updatedAt,
          );
          _contactProfiles[lower] = profile;
          await context.read<SettingsRepository>().saveContactProfile(_accountId, profile);
        }
      } catch (_) {}
    }

    final fullName = (profile?.fullname ?? '').trim();
    final username =
        (profile?.username ?? '').trim().replaceFirst(RegExp(r'^@+'), '');
    final autoName = fullName.isNotEmpty
        ? fullName
        : (username.isNotEmpty ? username : 'peer_${lower.substring(0, 8)}');

    _whitelist = [
      ..._whitelist,
      WhitelistEntry(bytes: _hexToBytes32(lower), name: autoName),
    ];
    _nicknames[lower] = autoName;
    _config = _config.copyWith(
      whitelist: _whitelist.map((e) => e.hexKey).toSet(),
    );

    final repo = context.read<SettingsRepository>();
    await repo.saveWhitelistEntriesForNode(_accountId, _whitelist);
    _roomsBloc
        .add(RoomsUpdateWhitelist(_whitelist.map((e) => e.hexKey).toSet()));
    _roomsBloc.add(
        RoomsUpdateNicknames({for (final e in _whitelist) e.hexKey: e.name}));
    if (mounted) setState(() {});
  }

  Future<void> _syncFriendStates(UserDirClient client) async {
    final snapshot = await client.friendSync(
      myPubkey: _config.myPublicKey,
      identityKeyPair: _config.identityKeyPair,
    );
    if (snapshot == null) {
      AppLogger.w('FRIEND_SYNC skipped: no response', tag: 'UDIR');
      return;
    }

    final next = <String, FriendStateRecord>{};
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    for (final item in snapshot) {
      final peerHex = item.peerPubkeyHex.toLowerCase();
      final status = switch (item.status) {
        UserDirFriendStatus.pendingOutgoing =>
          FriendStatus.pendingOutgoing.name,
        UserDirFriendStatus.pendingIncoming =>
          FriendStatus.pendingIncoming.name,
        UserDirFriendStatus.friend => FriendStatus.friend.name,
        UserDirFriendStatus.rejected => FriendStatus.rejected.name,
        _ => FriendStatus.none.name,
      };
      next[peerHex] = FriendStateRecord(
        peerPubkeyHex: peerHex,
        status: status,
        roomUUIDHex: item.roomUUIDHex,
        updatedAt: now,
      );

      if (item.status == UserDirFriendStatus.pendingIncoming) {
        final cached = _contactProfiles[peerHex];
        UserDirMeta? meta;
        try {
          meta = await client.getMeta(item.peerPubkey);
        } catch (_) {}
        if (meta != null) {
          _contactProfiles[peerHex] = ContactProfile(
            pubkeyHex: peerHex,
            username: meta.username,
            fullname: meta.fullname,
            avatarBytes: cached?.avatarBytes,
            avatarSha256Hex: meta.avatarSha256Hex,
            updatedAt: meta.updatedAt,
          );
          await context.read<SettingsRepository>().saveContactProfile(
            _accountId,
            _contactProfiles[peerHex]!,
          );
        }
      }

      if (item.status == UserDirFriendStatus.friend) {
        if (!_whitelist.any((e) => e.hexKey.toLowerCase() == peerHex)) {
          await _ensureContactForPeer(peerHex);
        }
      }

      if (item.status == UserDirFriendStatus.friend &&
          item.roomUUIDHex != null) {
        await _upsertDmChat(
          roomUUIDHex: item.roomUUIDHex!,
          peerHex: peerHex,
        );
      }
    }

    _friendStates = next;
    final repo = context.read<SettingsRepository>();
    await repo.saveFriendStates(_accountId, _friendStates);
    await repo.saveWhitelistEntriesForNode(_accountId, _whitelist);
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _upsertDmChat({
    required String roomUUIDHex,
    required String peerHex,
  }) async {
    final room = roomUUIDHex.toLowerCase().replaceAll('-', '');
    if (room.length != 32) return;
    final profile = _contactProfiles[peerHex];
    final nickname = _nicknames[peerHex] ?? 'Friend';
    final nameCandidate = profile?.fullname?.trim() ?? '';
    final displayName = nameCandidate.isNotEmpty ? nameCandidate : nickname;
    final repo = context.read<ChatStorageGateway>().metadataForAccount(_accountId);
    final existing = await repo.loadChat(room, serverAddress: _serverAddress);
    final now = DateTime.now();
    await repo.saveChat(ChatMetadata(
      uuid: room,
      name: displayName,
      serverAddress: _serverAddress,
      avatarBytes: profile?.avatarBytes ?? existing?.avatarBytes,
      createdAt: existing?.createdAt ?? now,
      updatedAt: now,
      windowWidth: existing?.windowWidth,
      windowHeight: existing?.windowHeight,
    ));
  }

  Future<void> _initUserDir() async {
    if (_accountId.trim().isEmpty) {
      AppLogger.w('UDIR skip: no accountId', tag: 'UDIR');
      return;
    }
    final repo = context.read<SettingsRepository>();
    final nodes = await repo.loadNodes();
    final currentNodeId = (_config.nodeId ?? '').trim();
    final node = currentNodeId.isNotEmpty
        ? nodes.where((n) => n.id == currentNodeId).firstOrNull
        : await repo.loadPreferredNode();
    if (node == null) {
      AppLogger.w('UDIR skip: node not found (nodeId=$currentNodeId)',
          tag: 'UDIR');
      return;
    }
    final opts = await repo.loadNodeServerOptions(node.id);
    if (opts == null) {
      AppLogger.w(
          'UDIR skip: no cached server options for "$_serverAddress" '
          '(run discovery first)',
          tag: 'UDIR');
      return;
    }

    final client = UserDirClient.forNode(node, opts);
    if (client == null) {
      AppLogger.w('UDIR skip: no usable transport (opts=$opts)', tag: 'UDIR');
      return;
    }

    AppLogger.i('UDIR connecting via ${client.label}', tag: 'UDIR');
    try {
      await client.connect();
      _userDirClient?.close();
      _userDirSub?.cancel();
      _friendDirSub?.cancel();
      _friendSyncTimer?.cancel();
      _userDirClient = client;

      // Register/update our own profile on the server
      await _registerSelf();

      if (_whitelist.isNotEmpty) {
        await _syncContactsFromUserDir(client);
      }

      // Subscribe to contacts + self so friend notifications arrive.
      final keys = <Uint8List>[
        ..._whitelist.map((e) => e.bytes),
        _config.myPublicKey
      ];
      await client.subscribe(keys);
      _userDirSub = client.notifyStream.listen((meta) {
        _notifyQueue = _notifyQueue.then((_) => _handleNotify(meta, client));
      });
      _friendDirSub = client.friendNotifyStream.listen((_) {
        _notifyQueue = _notifyQueue.then((_) => _syncFriendStates(client));
      });
      _friendSyncTimer = Timer.periodic(const Duration(seconds: 6), (_) {
        final c = _userDirClient;
        if (c == null || !c.isConnected) return;
        _notifyQueue = _notifyQueue.then((_) => _syncFriendStates(c));
      });
      _profileRegisterTimer?.cancel();
      _profileRegisterTimer = Timer.periodic(const Duration(seconds: 10), (_) {
        unawaited(_registerSelf());
      });
      await _syncFriendStates(client);
      for (final entry in _whitelist) {
        final st = _friendStates[entry.hexKey.toLowerCase()]?.statusEnum ??
            FriendStatus.none;
        if (st == FriendStatus.none) {
          await _sendFriendRequestFor(entry);
        }
      }
    } catch (e, st) {
      AppLogger.e('UDIR init failed: $e\n$st', tag: 'UDIR');
    }
  }

  Future<void> _syncContactsFromUserDir(UserDirClient client) async {
    final settings = context.read<SettingsRepository>();
    final cached = await settings.loadAllContactProfiles(_accountId);

    // GET_META -> compare sha256 -> GET_PROFILE if stale
    for (final contact in _whitelist) {
      if (!mounted) break;
      final meta = await client.getMeta(contact.bytes);
      if (meta == null) continue;

      final cachedProfile = cached[contact.hexKey];
      if (cachedProfile == null ||
          cachedProfile.avatarSha256Hex != meta.avatarSha256Hex ||
          cachedProfile.avatarBytes == null) {
        // Avatar stale or missing: fetch full profile.
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
        // Name/username changed, avatar is same.
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
    _pushContactAvatarsToRooms();
  }

  Future<void> _refreshContactsFromServer() async {
    final client = _userDirClient;
    if (client == null) {
      await _initUserDir();
      return;
    }
    if (_whitelist.isNotEmpty) {
      await _syncContactsFromUserDir(client);
    }
    await _syncFriendStates(client);
  }

  Future<void> _handleNotify(UserDirMeta meta, UserDirClient client) async {
    if (!mounted) return;
    final settings = context.read<SettingsRepository>();
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
    _pushContactAvatarsToRooms();
  }

  void _showAddSheet() {
    _roomsPageKey.currentState?.showAddSheet();
  }

  void _onUserAvatarChanged(Uint8List? avatar) {
    setState(() => _userAvatar = avatar);
    _roomsBloc.setUserAvatar(avatar);
    unawaited(_registerSelf(force: true));
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
                var client = _userDirClient;
                if (client == null || !client.isConnected) {
                  await _initUserDir();
                  client = _userDirClient;
                }
                if (client == null || !client.isConnected) return false;
                final ok = await client.sendFriendResponse(
                  myPubkey: _config.myPublicKey,
                  requesterPubkey: _hexToBytes32(peerHex),
                  accept: accept,
                  identityKeyPair: _config.identityKeyPair,
                );
                if (ok && accept) {
                  _suppressedContacts.remove(peerHex.toLowerCase());
                  await context.read<SettingsRepository>().saveSuppressedContacts(
                    _accountId,
                    _suppressedContacts,
                  );
                  await _ensureContactForPeer(peerHex);
                }
                if (ok) await _syncFriendStates(client);
                return ok;
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
    _checkAndNavigate();
  }

  Future<void> _checkAndNavigate() async {
    final settings = context.read<SettingsRepository>();
    final lastAddr = await settings.getLastAddress() ?? '';
    var accountId = ((await settings.loadLastAccountId()) ?? '').trim();
    final preferredNode = await settings.loadPreferredNode();
    final allNodes = await settings.loadNodes();

    if (accountId.isEmpty && preferredNode != null) {
      final fromNode = preferredNode.effectiveAccountId.trim();
      if (fromNode.isNotEmpty) {
        accountId = fromNode;
        await settings.setLastAccountId(accountId);
      }
    }
    if (accountId.isEmpty) {
      final all = await settings.loadAccountIds();
      if (all.isNotEmpty) {
        accountId = all.first;
        await settings.setLastAccountId(accountId);
      }
    }
    final nickname = accountId.isEmpty
        ? ''
        : await settings.loadUserNicknameForNode(accountId);
    final hasServerConfigured = preferredNode != null || allNodes.isNotEmpty;
    final hasProfileConfigured =
        accountId.isNotEmpty && nickname.trim().isNotEmpty;
    if (!hasServerConfigured || !hasProfileConfigured) {
      if (!mounted) return;
      final completed = await Navigator.of(context).push<bool>(
        MaterialPageRoute(builder: (_) => const OnboardingPage()),
      );
      if (completed == true && mounted) {
        await _checkAndNavigate();
      }
      return;
    }

    if (accountId.isEmpty) {
      accountId = uuidBytesToHex(generateUUIDv7());
      await settings.upsertAccountId(accountId);
      await settings.saveUserNicknameForNode(accountId, 'Account');
      await settings.setLastAccountId(accountId);
    }
    final chatServer = preferredNode?.chatAddress ??
        (lastAddr.isEmpty ? 'localhost:443' : lastAddr);

    if (accountId.trim().isNotEmpty) {
      await settings.migrateLegacyAccountDataToNodeIfNeeded(accountId);
    }

    var savedKey = await settings.loadPrivateKeyForNode(accountId);
    savedKey ??= await settings.loadPrivateKey(); // legacy fallback

    // First launch (per-account): auto-generate an Ed25519 identity key silently.
    if (savedKey == null) {
      savedKey = await _autoGenerateKey(settings, accountId);
    }

    // If key generation somehow failed, retry startup instead of hanging forever.
    if (savedKey == null) {
      if (mounted) {
        Future.delayed(const Duration(milliseconds: 500), _checkAndNavigate);
      }
      return;
    }

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
        accountId: accountId,
        serverAddr: chatServer,
        roomUUID: Uint8List(16),
        identityKeyPair: keyPair,
        myPublicKey: parsed.publicKey,
        whitelist: whitelist,
        transport: preferredNode?.transport ?? SgtpTransportFamily.tcp,
        useTls: preferredNode?.useTls ?? false,
        nodeId: preferredNode?.id,
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
    while (padded.length % 8 != 0) {
      padded.add(pad++);
    }
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
