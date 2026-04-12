import 'dart:async';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'package:sgtp_flutter/core/app_logger.dart';
import 'package:sgtp_flutter/core/network/sgtp_rpc_client.dart';
import 'package:sgtp_flutter/core/network/rpc_models/auth_rpc_models.dart';
import 'package:sgtp_flutter/core/network/rpc_models/profile_rpc_models.dart';
import 'package:sgtp_flutter/core/network/rpc_models/friend_rpc_models.dart';
import 'package:sgtp_flutter/core/network/rpc_models/friend_request_rpc_models.dart';
import 'package:sgtp_flutter/core/network/rpc_models/rpc_enums.dart';
import 'package:sgtp_flutter/features/contacts/domain/repositories/i_user_dir_client.dart';

export 'package:sgtp_flutter/features/contacts/domain/repositories/i_user_dir_client.dart';

const _tag = 'UDIR';

class UserDirClient implements IUserDirClient {
  final SgtpRpcClient _rpc;
  @override
  final String label;

  bool _connected = false;

  final StreamController<UserDirMeta> _notifyCtrl =
      StreamController<UserDirMeta>.broadcast();
  final StreamController<UserDirFriendNotify> _friendNotifyCtrl =
      StreamController<UserDirFriendNotify>.broadcast();

  /// Cache of pending incoming friend requests: senderPubkeyHex → requestId.
  final Map<String, Uint8List> _incomingRequestIds = {};

  UserDirClient({required SgtpRpcClient rpc, required this.label}) : _rpc = rpc;

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
    await _rpc.transport.connect();
    _connected = true;
    AppLogger.d('Connected via $label', tag: _tag);
  }

  @override
  void close() {
    _connected = false;
    _rpc.transport.close().ignore();
    if (!_notifyCtrl.isClosed) _notifyCtrl.close();
    if (!_friendNotifyCtrl.isClosed) _friendNotifyCtrl.close();
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
      final authError = await _rpc.authenticate(pubkey, identityKeyPair);
      if (authError != null) return (ok: false, errorMessage: authError);

      final req = UpdateProfileRequest(
        username: username.trim().isEmpty ? null : username.trim(),
        displayName: fullname.trim().isEmpty ? null : fullname.trim(),
      );
      final raw = await _rpc.callRpc(req);
      UpdateProfileResponse.fromMap(raw);
      AppLogger.d('Profile updated for ${_hexShort(pubkey)}', tag: _tag);
      return (ok: true, errorMessage: null);
    } catch (e) {
      AppLogger.e('registerWithResult failed: $e', tag: _tag);
      return (ok: false, errorMessage: e.toString());
    }
  }

  @override
  Future<UserDirMeta?> getMeta(Uint8List pubkey) async {
    try {
      final req = GetProfileRequest(userPublicKey: pubkey);
      final raw = await _rpc.callRpc(req);
      final res = GetProfileResponse.fromMap(raw);
      return _profileToMeta(res.profile);
    } catch (e) {
      AppLogger.w('getMeta failed for ${_hexShort(pubkey)}: $e', tag: _tag);
      return null;
    }
  }

  @override
  Future<UserDirProfile?> getProfile(Uint8List pubkey) async {
    try {
      final req = GetProfileRequest(userPublicKey: pubkey);
      final profileRaw = await _rpc.callRpc(req);
      final profileRes = GetProfileResponse.fromMap(profileRaw);

      Uint8List avatarBytes = Uint8List(0);
      try {
        final avatarReq = GetProfileAvatarRequest(userPublicKey: pubkey);
        final avatarRaw = await _rpc.callRpc(avatarReq);
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
      AppLogger.w('getProfile failed for ${_hexShort(pubkey)}: $e', tag: _tag);
      return null;
    }
  }

  @override
  Future<List<UserDirMeta>> search(String query, {int limit = 20}) async {
    try {
      final req = SearchProfilesRequest(query: query, limit: limit);
      final raw = await _rpc.callRpc(req);
      final res = SearchProfilesResponse.fromMap(raw);
      return res.items.map(_searchItemToMeta).toList();
    } catch (e) {
      AppLogger.w('search failed for "$query": $e', tag: _tag);
      return [];
    }
  }

  @override
  Future<bool> subscribe(List<Uint8List> pubkeys) async {
    try {
      final req = SubscribeToEventsRequest(
        requestedAtUs: DateTime.now().microsecondsSinceEpoch,
      );
      await _rpc.callRpc(req);
      return true;
    } catch (e) {
      AppLogger.w('subscribe failed: $e', tag: _tag);
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
      final req = SendFriendRequestRequest(receiverPublicKey: peerPubkey);
      await _rpc.callRpc(req);
      return true;
    } catch (e) {
      AppLogger.w('sendFriendRequest failed: $e', tag: _tag);
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
      AppLogger.w(
        'sendFriendResponse: no cached requestId for $requesterHex — syncing',
        tag: _tag,
      );
      await friendSync(myPubkey: myPubkey, identityKeyPair: identityKeyPair);
      requestId = _incomingRequestIds[requesterHex];
    }

    if (requestId == null) {
      AppLogger.e('sendFriendResponse: requestId not found', tag: _tag);
      return false;
    }

    return _doRespondToRequest(requestId, accept);
  }

  Future<bool> _doRespondToRequest(Uint8List requestId, bool accept) async {
    try {
      if (accept) {
        await _rpc.callRpc(AcceptFriendRequestRequest(requestId: requestId));
      } else {
        await _rpc.callRpc(DeclineFriendRequestRequest(requestId: requestId));
      }
      return true;
    } catch (e) {
      AppLogger.w('friendResponse(accept=$accept) failed: $e', tag: _tag);
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
      final req = RemoveFriendRequest(friendPublicKey: peerPubkey);
      await _rpc.callRpc(req);
      return true;
    } catch (e) {
      AppLogger.w('sendFriendDelete failed: $e', tag: _tag);
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

      final friendsRaw = await _rpc.callRpc(ListFriendsRequest());
      final friendsRes = ListFriendsResponse.fromMap(friendsRaw);
      for (final item in friendsRes.items) {
        final hex = _pubkeyHex(item.friendPublicKey);
        states[hex] = UserDirFriendState(
          peerPubkey: item.friendPublicKey,
          status: UserDirFriendStatus.friend,
        );
      }

      _incomingRequestIds.clear();
      final reqRaw = await _rpc.callRpc(ListFriendRequestsRequest());
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
      AppLogger.w('friendSync failed: $e', tag: _tag);
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

}
