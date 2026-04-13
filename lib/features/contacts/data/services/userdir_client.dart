import 'dart:async';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'package:sgtp_flutter/core/app_log.dart';
import 'package:sgtp_flutter/core/network/sgtp_rpc_client.dart';
import 'package:sgtp_flutter/core/network/rpc_models/auth_rpc_models.dart';
import 'package:sgtp_flutter/core/network/rpc_models/profile_rpc_models.dart';
import 'package:sgtp_flutter/core/network/rpc_models/friend_rpc_models.dart';
import 'package:sgtp_flutter/core/network/rpc_models/friend_request_rpc_models.dart';
import 'package:sgtp_flutter/core/network/rpc_models/rpc_enums.dart';
import 'package:sgtp_flutter/features/contacts/domain/repositories/i_user_dir_client.dart';

export 'package:sgtp_flutter/features/contacts/domain/repositories/i_user_dir_client.dart';

class UserDirClient implements IUserDirClient {
  final Future<SgtpRpcClient> Function() _rpcProvider;
  @override
  final String label;

  SgtpRpcClient? _rpc;
  bool _connected = false;

  final StreamController<UserDirMeta> _notifyCtrl =
      StreamController<UserDirMeta>.broadcast();
  final StreamController<UserDirFriendNotify> _friendNotifyCtrl =
      StreamController<UserDirFriendNotify>.broadcast();

  /// Cache of pending incoming friend requests: senderPubkeyHex → requestId.
  final Map<String, Uint8List> _incomingRequestIds = {};

  final _log = AppLog('UserDirClient');

  UserDirClient({
    required Future<SgtpRpcClient> Function() rpcProvider,
    required this.label,
  }) : _rpcProvider = rpcProvider;

  // ── IUserDirClient ───────────────────────────────────────────────────────

  @override
  bool get isConnected => _connected;

  @override
  Stream<UserDirMeta> get notifyStream => _notifyCtrl.stream;

  @override
  Stream<UserDirFriendNotify> get friendNotifyStream =>
      _friendNotifyCtrl.stream;

  @override
  Future<void> connect() async {
    if (_connected) return;
    await _resolveRpc();
    _connected = true;
    _log.debug('Connected via {label}', parameters: {'label': label});
  }

  @override
  void close() {
    _connected = false;
  }

  // ── Auth + profile ─��─────────────────────────────────────────────────────

  @override
  Future<({bool ok, String? errorMessage})> registerWithResult({
    required String username,
    required String fullname,
    required Uint8List pubkey,
    required Uint8List avatarBytes,
    required SimpleKeyPairData identityKeyPair,
  }) async {
    try {
      final rpc = await _resolveRpc();
      final authError = await rpc.authenticate(pubkey, identityKeyPair);
      if (authError != null) return (ok: false, errorMessage: authError);

      final req = UpdateProfileRequest(
        username: username.trim().isEmpty ? null : username.trim(),
        displayName: fullname.trim().isEmpty ? null : fullname.trim(),
      );
      final raw = await rpc.callRpc(req);
      UpdateProfileResponse.fromMap(raw);
      _log.debug('Profile updated for {pubkey}', parameters: {'pubkey': _hexShort(pubkey)});
      return (ok: true, errorMessage: null);
    } catch (e) {
      _log.error('registerWithResult failed: {error}', parameters: {'error': e});
      return (ok: false, errorMessage: e.toString());
    }
  }

  @override
  Future<UserDirMeta?> getMeta(Uint8List pubkey) async {
    try {
      final rpc = await _resolveRpc();
      final req = GetProfileRequest(userPublicKey: pubkey);
      final raw = await rpc.callRpc(req);
      final res = GetProfileResponse.fromMap(raw);
      return _profileToMeta(res.profile);
    } catch (e) {
      _log.warning('getMeta failed for {pubkey}: {error}', parameters: {'pubkey': _hexShort(pubkey), 'error': e});
      return null;
    }
  }

  @override
  Future<UserDirProfile?> getProfile(Uint8List pubkey) async {
    try {
      final rpc = await _resolveRpc();
      final req = GetProfileRequest(userPublicKey: pubkey);
      final profileRaw = await rpc.callRpc(req);
      final profileRes = GetProfileResponse.fromMap(profileRaw);

      Uint8List avatarBytes = Uint8List(0);
      try {
        final avatarReq = GetProfileAvatarRequest(userPublicKey: pubkey);
        final avatarRaw = await rpc.callRpc(avatarReq);
        final avatarRes = GetProfileAvatarResponse.fromMap(avatarRaw);
        avatarBytes = avatarRes.avatarBytes;
      } catch (_) {}

      final meta = _profileToMeta(profileRes.profile);
      return UserDirProfile(
        pubkey: meta.pubkey,
        username: meta.username,
        fullname: meta.fullname,
        avatarSha256: meta.avatarSha256,
        updatedAt: meta.updatedAt,
        avatarBytes: avatarBytes,
      );
    } catch (e) {
      _log.warning('getProfile failed for {pubkey}: {error}', parameters: {'pubkey': _hexShort(pubkey), 'error': e});
      return null;
    }
  }

  @override
  Future<List<UserDirMeta>> search(String query, {int limit = 20}) async {
    try {
      final rpc = await _resolveRpc();
      final req = SearchProfilesRequest(query: query, limit: limit);
      final raw = await rpc.callRpc(req);
      final res = SearchProfilesResponse.fromMap(raw);
      return res.items.map(_searchItemToMeta).toList();
    } catch (e) {
      _log.warning('search failed for "{query}": {error}', parameters: {'query': query, 'error': e});
      return [];
    }
  }

  @override
  Future<bool> subscribe(List<Uint8List> pubkeys) async {
    try {
      final rpc = await _resolveRpc();
      final req = SubscribeToEventsRequest(
        requestedAtUs: DateTime.now().microsecondsSinceEpoch,
      );
      await rpc.callRpc(req);
      return true;
    } catch (e) {
      _log.warning('subscribe failed: {error}', parameters: {'error': e});
      return false;
    }
  }

  // ── Friend operations ──��─────────────────────────────────────────────────

  @override
  Future<bool> sendFriendRequest({
    required Uint8List myPubkey,
    required Uint8List peerPubkey,
    required SimpleKeyPairData identityKeyPair,
  }) async {
    try {
      final rpc = await _resolveRpc();
      final req = SendFriendRequestRequest(receiverPublicKey: peerPubkey);
      await rpc.callRpc(req);
      return true;
    } catch (e) {
      _log.warning('sendFriendRequest failed: {error}', parameters: {'error': e});
      return false;
    }
  }

  @override
  Future<bool> sendFriendResponse({
    required Uint8List myPubkey,
    required Uint8List requesterPubkey,
    required bool accept,
    required SimpleKeyPairData identityKeyPair,
  }) async {
    final requesterHex = _pubkeyHex(requesterPubkey);
    var requestId = _incomingRequestIds[requesterHex];

    if (requestId == null) {
      _log.warning('sendFriendResponse: no cached requestId for {requester} — syncing', parameters: {'requester': requesterHex});
      await friendSync(myPubkey: myPubkey, identityKeyPair: identityKeyPair);
      requestId = _incomingRequestIds[requesterHex];
    }

    if (requestId == null) {
      _log.error('sendFriendResponse: requestId not found');
      return false;
    }

    return _doRespondToRequest(requestId, accept);
  }

  Future<bool> _doRespondToRequest(Uint8List requestId, bool accept) async {
    try {
      final rpc = await _resolveRpc();
      if (accept) {
        await rpc.callRpc(AcceptFriendRequestRequest(requestId: requestId));
      } else {
        await rpc.callRpc(DeclineFriendRequestRequest(requestId: requestId));
      }
      return true;
    } catch (e) {
      _log.warning('friendResponse(accept={accept}) failed: {error}', parameters: {'accept': accept, 'error': e});
      return false;
    }
  }

  @override
  Future<bool> sendFriendDelete({
    required Uint8List myPubkey,
    required Uint8List peerPubkey,
    required SimpleKeyPairData identityKeyPair,
  }) async {
    try {
      final rpc = await _resolveRpc();
      final req = RemoveFriendRequest(friendPublicKey: peerPubkey);
      await rpc.callRpc(req);
      return true;
    } catch (e) {
      _log.warning('sendFriendDelete failed: {error}', parameters: {'error': e});
      return false;
    }
  }

  @override
  Future<List<UserDirFriendState>?> friendSync({
    required Uint8List myPubkey,
    required SimpleKeyPairData identityKeyPair,
  }) async {
    try {
      final states = <String, UserDirFriendState>{};
      final rpc = await _resolveRpc();

      final friendsRaw = await rpc.callRpc(ListFriendsRequest());
      final friendsRes = ListFriendsResponse.fromMap(friendsRaw);
      for (final item in friendsRes.items) {
        final hex = _pubkeyHex(item.friendPublicKey);
        states[hex] = UserDirFriendState(
          peerPubkey: item.friendPublicKey,
          status: UserDirFriendStatus.friend,
        );
      }

      _incomingRequestIds.clear();
      final reqRaw = await rpc.callRpc(ListFriendRequestsRequest());
      final reqRes = ListFriendRequestsResponse.fromMap(reqRaw);
      final myHex = _pubkeyHex(myPubkey);

      for (final item in reqRes.items) {
        if (item.state != FriendRequestStateEnum.pending) continue;
        final senderHex = _pubkeyHex(item.senderPublicKey);
        final receiverHex = _pubkeyHex(item.receiverPublicKey);

        if (receiverHex == myHex) {
          _incomingRequestIds[senderHex] = item.requestId;
          states.putIfAbsent(
            senderHex,
            () => UserDirFriendState(
              peerPubkey: item.senderPublicKey,
              status: UserDirFriendStatus.pendingIncoming,
            ),
          );
        } else if (senderHex == myHex) {
          states.putIfAbsent(
            receiverHex,
            () => UserDirFriendState(
              peerPubkey: item.receiverPublicKey,
              status: UserDirFriendStatus.pendingOutgoing,
            ),
          );
        }
      }

      return states.values.toList();
    } catch (e) {
      _log.warning('friendSync failed: {error}', parameters: {'error': e});
      return null;
    }
  }

  // ── Private helpers ──────────────────────────────────────────────────────

  static UserDirMeta _profileToMeta(ProfileData p) => UserDirMeta(
        pubkey: p.publicKey,
        username: p.username,
        fullname:
            (p.displayName?.isNotEmpty == true) ? p.displayName! : p.username,
        avatarSha256: Uint8List(0),
        updatedAt: p.lastSeenAtUs ~/ 1000000,
      );

  static UserDirMeta _searchItemToMeta(ProfileSearchItem item) => UserDirMeta(
        pubkey: item.publicKey,
        username: item.username,
        fullname: (item.displayName?.isNotEmpty == true)
            ? item.displayName!
            : item.username,
        avatarSha256: Uint8List(0),
        updatedAt: 0,
      );

  static String _pubkeyHex(Uint8List key) =>
      key.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  static String _hexShort(Uint8List key) => _pubkeyHex(key).substring(0, 8);

  Future<SgtpRpcClient> _resolveRpc() async {
    final rpc = _rpc;
    if (rpc != null) return rpc;
    final resolved = await _rpcProvider();
    _rpc = resolved;
    return resolved;
  }

}
