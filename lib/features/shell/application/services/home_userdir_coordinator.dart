import 'dart:async';
import 'dart:typed_data';

import 'package:sgtp_flutter/core/app_log.dart';
import 'package:sgtp_flutter/features/contacts/domain/repositories/i_user_dir_client.dart';
import 'package:sgtp_flutter/features/shell/application/models/home_userdir_models.dart';
import 'package:sgtp_flutter/features/shell/application/services/home_persistence_service.dart';
import 'package:sgtp_flutter/features/shell/application/services/home_userdir_support_service.dart';
import 'package:sgtp_flutter/features/setup/domain/entities/contact_directory_models.dart';

final _log = AppLog('HomeUserDirCoordinator');

class HomeUserDirCoordinator {
  HomeUserDirCoordinator({
    required HomePersistenceService persistenceService,
    required HomeUserDirSupportService supportService,
    required UserDirClientFactory userDirClientFactory,
    required Future<void> Function(
      String roomUUIDHex,
      String peerHex,
      String displayName,
      Uint8List? avatarBytes,
    ) onDirectMessageReady,
    required void Function(HomeUserDirState state) onStateChanged,
  })  : _persistence = persistenceService,
        _support = supportService,
        _clientFactory = userDirClientFactory,
        _onDirectMessageReady = onDirectMessageReady,
        _onStateChanged = onStateChanged;

  final HomePersistenceService _persistence;
  final HomeUserDirSupportService _support;
  final UserDirClientFactory _clientFactory;
  final Future<void> Function(
    String roomUUIDHex,
    String peerHex,
    String displayName,
    Uint8List? avatarBytes,
  ) _onDirectMessageReady;
  final void Function(HomeUserDirState state) _onStateChanged;

  IUserDirClient? _client;
  StreamSubscription<UserDirMeta>? _userDirSub;
  StreamSubscription<UserDirFriendNotify>? _friendDirSub;
  Timer? _friendSyncTimer;
  Timer? _profileRegisterTimer;
  Future<void> _notifyQueue = Future.value();
  String _lastRegisteredFingerprint = '';
  String _desiredProfileFingerprint = '';
  String _activeAccountId = '';

  Map<String, ContactProfile> _contactProfiles = {};
  Map<String, FriendStateRecord> _friendStates = {};
  Set<String> _suppressedContacts = {};
  List<WhitelistEntry> _whitelist = const [];
  Map<String, String> _nicknames = const {};

  HomeUserDirState get currentState => HomeUserDirState(
        contactProfiles: Map<String, ContactProfile>.from(_contactProfiles),
        friendStates: Map<String, FriendStateRecord>.from(_friendStates),
        suppressedContacts: Set<String>.from(_suppressedContacts),
        whitelist: List<WhitelistEntry>.from(_whitelist),
        nicknames: Map<String, String>.from(_nicknames),
      );

  Future<HomeUserDirState> start(HomeUserDirSession session) async {
    _activeAccountId = session.accountId.trim();
    _notifyQueue = Future.value();
    _lastRegisteredFingerprint = '';
    _desiredProfileFingerprint = _support.buildProfileFingerprint(
      publicKey: session.config.myPublicKey,
      nickname: session.nickname,
      username: session.username,
      userAvatar: session.userAvatar,
    );
    final accountState = await _persistence.loadAccountState(session.accountId);
    final storedProfiles =
        await _persistence.loadAllContactProfiles(session.accountId);
    _contactProfiles = {
      for (final e in storedProfiles.entries) e.key.toLowerCase(): e.value,
    };
    _friendStates =
        Map<String, FriendStateRecord>.from(accountState.friendStates);
    _suppressedContacts = Set<String>.from(accountState.suppressedContacts);
    _whitelist = _sanitizeWhitelist(session, session.whitelist);
    _nicknames = {for (final e in _whitelist) e.hexKey.toLowerCase(): e.name};
    if (_whitelist.length != session.whitelist.length) {
      await _persistence.saveWhitelistEntries(session.accountId, _whitelist);
    }
    _emit();
    await _initUserDir(session);
    return currentState;
  }

  Future<HomeUserDirState> refresh(HomeUserDirSession session) async {
    if (!_isCurrentSession(session)) return currentState;
    final client = _client;
    if (client == null || !client.isConnected) {
      await _initUserDir(session);
      return currentState;
    }
    if (_whitelist.isNotEmpty) {
      await _syncContactsFromUserDir(session, client);
    }
    await _syncFriendStates(session, client);
    return currentState;
  }

  Future<String?> registerSelf(
    HomeUserDirSession session, {
    bool force = false,
  }) async {
    if (!_isCurrentSession(session)) return null;
    final fp = _support.buildProfileFingerprint(
      publicKey: session.config.myPublicKey,
      nickname: session.nickname,
      username: session.username,
      userAvatar: session.userAvatar,
    );
    if (force) {
      _desiredProfileFingerprint = fp;
    } else if (_desiredProfileFingerprint.isNotEmpty &&
        _desiredProfileFingerprint != fp) {
      _log.debug('Skip stale profile registration snapshot');
      return null;
    }
    if (!force && _lastRegisteredFingerprint == fp) return null;

    Future<({bool ok, String? errorMessage})> doRegister(
      IUserDirClient client,
    ) {
      return client.registerWithResult(
        username: _support.buildUsername(session.username) ?? '',
        fullname: session.nickname,
        pubkey: session.config.myPublicKey,
        avatarBytes: session.userAvatar ?? Uint8List(0),
        identityKeyPair: session.config.identityKeyPair,
      );
    }

    var client = _client;
    if (client == null || !client.isConnected) {
      await _initUserDir(session);
      client = _client;
    }
    if (client == null || !client.isConnected) {
      return null;
    }

    var result = await doRegister(client);
    if (!result.ok && (result.errorMessage ?? '').trim().isEmpty) {
      await _initUserDir(session);
      final retry = _client;
      if (retry != null && retry.isConnected) {
        result = await doRegister(retry);
      }
    }

    if (result.ok) {
      _lastRegisteredFingerprint = fp;
      return null;
    }

    final msg = (result.errorMessage ?? '').trim();
    final lower = msg.toLowerCase();
    final isTaken = lower.contains('taken') ||
        lower.contains('exists') ||
        lower.contains('occupied') ||
        lower.contains('already');
    if (isTaken) return 'Username already taken';
    if (msg.isNotEmpty) return msg;
    return 'Username update failed';
  }

  Future<HomeUserDirState> applyWhitelistChanges({
    required HomeUserDirSession session,
    required List<WhitelistEntry> previousWhitelist,
    required List<WhitelistEntry> nextWhitelist,
    required Map<String, String> nextNicknames,
  }) async {
    if (!_isCurrentSession(session)) return currentState;
    _whitelist = _sanitizeWhitelist(session, nextWhitelist);
    _nicknames = {for (final e in _whitelist) e.hexKey.toLowerCase(): e.name};

    final oldSet = previousWhitelist.map((e) => e.hexKey.toLowerCase()).toSet();
    final nextSet = _whitelist.map((e) => e.hexKey.toLowerCase()).toSet();
    final removed = previousWhitelist
        .where((e) => !nextSet.contains(e.hexKey.toLowerCase()));
    final added =
        nextWhitelist.where((e) => !oldSet.contains(e.hexKey.toLowerCase()));

    if (removed.isNotEmpty) {
      for (final entry in removed) {
        _suppressedContacts.add(entry.hexKey.toLowerCase());
        await _removeFriendOnServer(session, entry.hexKey);
      }
      await _persistence.saveSuppressedContacts(
        session.accountId,
        _suppressedContacts,
      );
    }
    for (final entry in added) {
      final hex = entry.hexKey.toLowerCase();
      if (_suppressedContacts.remove(hex)) {
        await _persistence.saveSuppressedContacts(
          session.accountId,
          _suppressedContacts,
        );
      }
      await _sendFriendRequestFor(session, entry);
    }
    _emit();
    return currentState;
  }

  Future<bool> respondToFriend({
    required HomeUserDirSession session,
    required String peerHex,
    required bool accept,
  }) async {
    if (!_isCurrentSession(session)) return false;
    if (_isSelfHex(session, peerHex)) return false;
    var client = _client;
    if (client == null || !client.isConnected) {
      await _initUserDir(session);
      client = _client;
    }
    if (client == null || !client.isConnected) return false;

    final ok = await client.sendFriendResponse(
      myPubkey: session.config.myPublicKey,
      requesterPubkey: _support.hexToBytes32(peerHex),
      accept: accept,
      identityKeyPair: session.config.identityKeyPair,
    );
    if (ok && accept) {
      _suppressedContacts.remove(peerHex.toLowerCase());
      await _persistence.saveSuppressedContacts(
        session.accountId,
        _suppressedContacts,
      );
      await _ensureContactForPeer(session, peerHex);
    }
    if (ok) {
      await _syncFriendStates(session, client);
    }
    return ok;
  }

  Future<void> dispose() async {
    await _userDirSub?.cancel();
    await _friendDirSub?.cancel();
    _friendSyncTimer?.cancel();
    _profileRegisterTimer?.cancel();
    _client?.close();
    _client = null;
    _activeAccountId = '';
    _notifyQueue = Future.value();
  }

  Future<void> _removeFriendOnServer(
    HomeUserDirSession session,
    String peerHex,
  ) async {
    if (!_isCurrentSession(session)) return;
    if (_isSelfHex(session, peerHex)) return;
    var client = _client;
    if (client == null || !client.isConnected) {
      await _initUserDir(session);
      client = _client;
    }
    if (client == null || !client.isConnected) return;
    try {
      final ok = await client.sendFriendDelete(
        myPubkey: session.config.myPublicKey,
        peerPubkey: _support.hexToBytes32(peerHex),
        identityKeyPair: session.config.identityKeyPair,
      );
      _log.info('FRIEND_DELETE {status} peer={peer}', parameters: {
        'status': ok ? 'sent' : 'failed',
        'peer': peerHex.substring(0, 8)
      });
      if (ok) {
        await _syncFriendStates(session, client);
      }
    } catch (_) {}
  }

  Future<void> _sendFriendRequestFor(
    HomeUserDirSession session,
    WhitelistEntry entry,
  ) async {
    if (!_isCurrentSession(session)) return;
    if (_isSelfHex(session, entry.hexKey)) return;
    var client = _client;
    if (client == null || !client.isConnected) {
      await _initUserDir(session);
      client = _client;
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
        myPubkey: session.config.myPublicKey,
        peerPubkey: entry.bytes,
        identityKeyPair: session.config.identityKeyPair,
      );
      _log.info('FRIEND_REQUEST {status} peer={peer}', parameters: {
        'status': ok ? 'sent' : 'failed',
        'peer': hex.substring(0, 8)
      });
      await _syncFriendStates(session, client);
    } catch (_) {}
  }

  Future<void> _ensureContactForPeer(
    HomeUserDirSession session,
    String peerHex,
  ) async {
    if (!_isCurrentSession(session)) return;
    final lower = peerHex.toLowerCase();
    if (_isSelfHex(session, lower)) return;
    if (_suppressedContacts.contains(lower)) return;
    if (_whitelist.any((e) => e.hexKey.toLowerCase() == lower)) return;

    ContactProfile? profile = _contactProfiles[lower];
    final client = _client;
    if (profile == null && client != null && client.isConnected) {
      try {
        final meta = await client.getMeta(_support.hexToBytes32(lower));
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
          await _persistence.saveContactProfile(session.accountId, profile);
        }
      } catch (_) {}
    }

    final fullName = (profile?.fullname ?? '').trim();
    final username =
        (profile?.username ?? '').trim().replaceFirst(RegExp(r'^@+'), '');
    final autoName = _bestContactName(
      fullName: fullName,
      username: username,
      fallback: 'peer_${lower.substring(0, 8)}',
    );

    _whitelist = [
      ..._whitelist,
      WhitelistEntry(bytes: _support.hexToBytes32(lower), name: autoName),
    ];
    _nicknames = {
      ..._nicknames,
      lower: autoName,
    };

    await _persistence.saveWhitelistEntries(session.accountId, _whitelist);
    _emit();
  }

  Future<void> _syncFriendStates(
    HomeUserDirSession session,
    IUserDirClient client,
  ) async {
    if (!_isCurrentSession(session)) return;
    final snapshot = await client.friendSync(
      myPubkey: session.config.myPublicKey,
      identityKeyPair: session.config.identityKeyPair,
    );
    if (snapshot == null) {
      _log.warning('FRIEND_SYNC skipped: no response');
      return;
    }

    final next = <String, FriendStateRecord>{};
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final selfHex = _pubkeyHex(session.config.myPublicKey);
    for (final item in snapshot) {
      final peerHex = item.peerPubkeyHex.toLowerCase();
      if (peerHex == selfHex) {
        // Defensive: ignore server states that target our own identity.
        continue;
      }
      final status = switch (item.status) {
        UserDirFriendStatus.pendingOutgoing => FriendStatus.pendingOutgoing,
        UserDirFriendStatus.pendingIncoming => FriendStatus.pendingIncoming,
        UserDirFriendStatus.friend => FriendStatus.friend,
        UserDirFriendStatus.rejected => FriendStatus.rejected,
        _ => FriendStatus.none,
      };
      if (status == FriendStatus.none) {
        // Ignore unknown/empty statuses from transient snapshots.
        continue;
      }
      final candidate = FriendStateRecord(
        peerPubkeyHex: peerHex,
        status: status.name,
        roomUUIDHex: item.roomUUIDHex,
        updatedAt: now,
      );
      final previous = next[peerHex];
      if (previous == null ||
          _friendStatusPriority(status) >
              _friendStatusPriority(previous.statusEnum)) {
        next[peerHex] = candidate;
      } else if (previous.roomUUIDHex == null &&
          candidate.roomUUIDHex != null) {
        next[peerHex] = previous.copyWith(
          roomUUIDHex: candidate.roomUUIDHex,
          updatedAt: now,
        );
      }

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
          await _persistence.saveContactProfile(
            session.accountId,
            _contactProfiles[peerHex]!,
          );
        }
      }

      if (item.status == UserDirFriendStatus.friend) {
        if (!_whitelist.any((e) => e.hexKey.toLowerCase() == peerHex)) {
          await _ensureContactForPeer(session, peerHex);
        }
      }

      if (item.status == UserDirFriendStatus.friend &&
          item.roomUUIDHex != null) {
        final profile = _contactProfiles[peerHex];
        final nickname = (_nicknames[peerHex] ?? '').trim();
        final fullName = profile?.fullname?.trim() ?? '';
        final username =
            (profile?.username ?? '').trim().replaceFirst(RegExp(r'^@+'), '');
        final displayName = _bestContactName(
          fullName: fullName,
          username: username,
          fallback: nickname.isNotEmpty ? nickname : 'Friend',
        );
        await _onDirectMessageReady(
          item.roomUUIDHex!,
          peerHex,
          displayName,
          profile?.avatarBytes,
        );
      }
    }

    _friendStates = _stabilizeFriendStates(
      previous: _friendStates,
      next: next,
      nowSec: now,
    );
    if (!_isCurrentSession(session)) return;
    await _persistence.saveFriendStates(session.accountId, _friendStates);
    await _persistence.saveWhitelistEntries(session.accountId, _whitelist);
    _emit();
  }

  Future<void> _initUserDir(HomeUserDirSession session) async {
    if (!_isCurrentSession(session)) return;
    if (session.accountId.trim().isEmpty) return;
    final resolved = session.resolvedNode;
    if (resolved == null) {
      _log.warning('RPC skip: server options not yet discovered');
      return;
    }
    _friendSyncTimer?.cancel();
    _profileRegisterTimer?.cancel();
    await _userDirSub?.cancel();
    await _friendDirSub?.cancel();
    _userDirSub = null;
    _friendDirSub = null;
    final previousClient = _client;
    _client = null;
    previousClient?.close();

    final client = _clientFactory(resolved.node, resolved.options);
    if (client == null) {
      _log.warning('RPC skip: no HTTP endpoint on node (opts={opts})',
          parameters: {'opts': resolved.options});
      return;
    }

    _log.info('RPC connecting via {label}',
        parameters: {'label': client.label});
    try {
      await client.connect();
      _client = client;

      await registerSelf(session, force: false);

      if (_whitelist.isNotEmpty) {
        await _syncContactsFromUserDir(session, client);
      }

      final keys = <Uint8List>[
        ..._whitelist.map((e) => e.bytes),
        session.config.myPublicKey,
      ];
      await client.subscribe(keys);
      _userDirSub = client.notifyStream.listen((meta) {
        _notifyQueue =
            _notifyQueue.then((_) => _handleNotify(session, meta, client));
      });
      _friendDirSub = client.friendNotifyStream.listen((_) {
        _notifyQueue =
            _notifyQueue.then((_) => _syncFriendStates(session, client));
      });
      _friendSyncTimer = Timer.periodic(const Duration(seconds: 6), (_) {
        final active = _client;
        if (active == null || !active.isConnected) return;
        _notifyQueue =
            _notifyQueue.then((_) => _syncFriendStates(session, active));
      });
      _profileRegisterTimer?.cancel();
      _profileRegisterTimer = Timer.periodic(const Duration(seconds: 10), (_) {
        unawaited(registerSelf(session, force: false));
      });
      await _syncFriendStates(session, client);
      // Do not auto-send friend requests on reconnect/refresh.
      // Requests are sent explicitly when the user adds a contact
      // (see applyWhitelistChanges -> _sendFriendRequestFor).
    } catch (e, st) {
      _log.error('RPC init failed: {error}',
          parameters: {'error': e}, error: e, stackTrace: st);
    }
  }

  Future<void> _syncContactsFromUserDir(
    HomeUserDirSession session,
    IUserDirClient client,
  ) async {
    if (!_isCurrentSession(session)) return;
    final cached = await _persistence.loadAllContactProfiles(session.accountId);
    for (final contact in _whitelist) {
      final meta = await client.getMeta(contact.bytes);
      if (meta == null) continue;

      final cachedProfile = cached[contact.hexKey];
      if (cachedProfile == null ||
          cachedProfile.avatarSha256Hex != meta.avatarSha256Hex ||
          cachedProfile.avatarBytes == null) {
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
        await _persistence.saveContactProfile(session.accountId, cp);
        _contactProfiles[contact.hexKey] = cp;
      } else if (cachedProfile.username != meta.username ||
          cachedProfile.fullname != meta.fullname) {
        final cp = ContactProfile(
          pubkeyHex: contact.hexKey,
          username: meta.username,
          fullname: meta.fullname,
          avatarBytes: cachedProfile.avatarBytes,
          avatarSha256Hex: meta.avatarSha256Hex,
          updatedAt: meta.updatedAt,
        );
        await _persistence.saveContactProfile(session.accountId, cp);
        _contactProfiles[contact.hexKey] = cp;
      } else {
        _contactProfiles[contact.hexKey] = cachedProfile;
      }
    }
    _emit();
  }

  Future<void> _handleNotify(
    HomeUserDirSession session,
    UserDirMeta meta,
    IUserDirClient client,
  ) async {
    if (!_isCurrentSession(session)) return;
    final cached = await _persistence.loadContactProfile(
      session.accountId,
      meta.pubkeyHex,
    );

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
      await _persistence.saveContactProfile(session.accountId, cp);
      _contactProfiles[meta.pubkeyHex] = cp;
    } else {
      final cp = ContactProfile(
        pubkeyHex: meta.pubkeyHex,
        username: meta.username,
        fullname: meta.fullname,
        avatarBytes: cached.avatarBytes,
        avatarSha256Hex: meta.avatarSha256Hex,
        updatedAt: meta.updatedAt,
      );
      await _persistence.saveContactProfile(session.accountId, cp);
      _contactProfiles[meta.pubkeyHex] = cp;
    }
    _emit();
  }

  void _emit() {
    _onStateChanged(currentState);
  }

  int _friendStatusPriority(FriendStatus status) => switch (status) {
        FriendStatus.none => 0,
        FriendStatus.rejected => 1,
        FriendStatus.pendingOutgoing => 2,
        FriendStatus.pendingIncoming => 3,
        FriendStatus.friend => 4,
      };

  List<WhitelistEntry> _sanitizeWhitelist(
    HomeUserDirSession session,
    List<WhitelistEntry> entries,
  ) {
    final selfHex = _pubkeyHex(session.config.myPublicKey);
    final seen = <String>{};
    final out = <WhitelistEntry>[];
    for (final e in entries) {
      final hex = e.hexKey.toLowerCase();
      if (hex == selfHex) continue;
      if (!seen.add(hex)) continue;
      out.add(e);
    }
    return out;
  }

  bool _isSelfHex(HomeUserDirSession session, String hex) =>
      hex.toLowerCase() == _pubkeyHex(session.config.myPublicKey);

  bool _isCurrentSession(HomeUserDirSession session) =>
      session.accountId.trim().isNotEmpty &&
      session.accountId.trim() == _activeAccountId;

  String _bestContactName({
    required String fullName,
    required String username,
    required String fallback,
  }) {
    final full = fullName.trim();
    final user = username.trim();
    // "Account" is onboarding default and often not a meaningful contact label.
    final fullIsGeneric = full.isEmpty || full.toLowerCase() == 'account';
    if (!fullIsGeneric) return full;
    if (user.isNotEmpty) return user;
    return fallback;
  }

  String _pubkeyHex(Uint8List key) =>
      key.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  Map<String, FriendStateRecord> _stabilizeFriendStates({
    required Map<String, FriendStateRecord> previous,
    required Map<String, FriendStateRecord> next,
    required int nowSec,
  }) {
    // Friend snapshots can be briefly incomplete during reconnect/replication.
    // Keep recent non-none states for a short grace window to avoid UI flicker.
    const int graceSeconds = 20;
    final merged = Map<String, FriendStateRecord>.from(next);
    for (final entry in previous.entries) {
      final key = entry.key;
      if (merged.containsKey(key)) continue;
      final old = entry.value;
      if (old.statusEnum == FriendStatus.none) continue;
      final age = nowSec - old.updatedAt;
      if (age <= graceSeconds) {
        merged[key] = old;
      }
    }
    return merged;
  }
}
