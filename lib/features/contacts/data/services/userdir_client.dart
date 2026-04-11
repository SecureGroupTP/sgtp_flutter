import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'package:sgtp_flutter/core/app_logger.dart';
import 'package:sgtp_flutter/core/network/sgtp_rpc_client.dart';
import 'package:sgtp_flutter/core/network/transport/http_protocol_transport.dart';
import 'package:sgtp_flutter/core/network/rpc_models/auth_rpc_models.dart';
import 'package:sgtp_flutter/core/network/rpc_models/profile_rpc_models.dart';
import 'package:sgtp_flutter/core/network/rpc_models/friend_rpc_models.dart';
import 'package:sgtp_flutter/core/network/rpc_models/friend_request_rpc_models.dart';
import 'package:sgtp_flutter/core/network/rpc_models/rpc_enums.dart';
import 'package:sgtp_flutter/core/sgtp_server_options.dart';
import 'package:sgtp_flutter/features/contacts/domain/repositories/i_user_dir_client.dart';
import 'package:sgtp_flutter/features/setup/domain/entities/node.dart';

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

  // ── Factory ──────────────────────────────────────────────────────────────

  static IUserDirClient? forNode(NodeConfig node, SgtpServerOptions opts) {
    final bool useTls;
    final int port;

    if (opts.httpTls && opts.httpTlsPort > 0) {
      useTls = true;
      port = opts.httpTlsPort;
    } else if (opts.http && opts.httpPort > 0) {
      useTls = false;
      port = opts.httpPort;
    } else {
      AppLogger.w(
        'No HTTP endpoint available for user-directory on ${node.host}',
        tag: _tag,
      );
      return null;
    }

    final transport = HttpProtocolTransport(
      host: node.host,
      port: port,
      useTls: useTls,
    );
    final rpc = SgtpRpcClient(transport);
    final scheme = useTls ? 'https' : 'http';
    return UserDirClient(rpc: rpc, label: '$scheme://${node.host}:$port');
  }

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
      final authError = await _authenticate(pubkey, identityKeyPair);
      if (authError != null) return (ok: false, errorMessage: authError);

      final req = UpdateProfileRequest(
        username: username.trim().isEmpty ? null : username.trim(),
        displayName: fullname.trim().isEmpty ? null : fullname.trim(),
      );
      final raw = await _rpc.callRpc('updateProfile', req.toMap());
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
      final raw = await _rpc.callRpc('getProfile', req.toMap());
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
      final profileRaw = await _rpc.callRpc('getProfile', req.toMap());
      final profileRes = GetProfileResponse.fromMap(profileRaw);

      Uint8List avatarBytes = Uint8List(0);
      try {
        final avatarReq = GetProfileAvatarRequest(userPublicKey: pubkey);
        final avatarRaw =
            await _rpc.callRpc('getProfileAvatar', avatarReq.toMap());
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
      final raw = await _rpc.callRpc('searchProfiles', req.toMap());
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
      await _rpc.callRpc('subscribeToEvents', req.toMap());
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
    _ensureCredentials(myPubkey, identityKeyPair);
    try {
      final req = SendFriendRequestRequest(receiverPublicKey: peerPubkey);
      await _rpc.callRpc('sendFriendRequest', req.toMap());
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
    _ensureCredentials(myPubkey, identityKeyPair);
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
        final req = AcceptFriendRequestRequest(requestId: requestId);
        await _rpc.callRpc('acceptFriendRequest', req.toMap());
      } else {
        final req = DeclineFriendRequestRequest(requestId: requestId);
        await _rpc.callRpc('declineFriendRequest', req.toMap());
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
    _ensureCredentials(myPubkey, identityKeyPair);
    try {
      final req = RemoveFriendRequest(friendPublicKey: peerPubkey);
      await _rpc.callRpc('removeFriend', req.toMap());
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
    _ensureCredentials(myPubkey, identityKeyPair);
    try {
      final states = <String, UserDirFriendState>{};

      final friendsRaw =
          await _rpc.callRpc('listFriends', ListFriendsRequest().toMap());
      final friendsRes = ListFriendsResponse.fromMap(friendsRaw);
      for (final item in friendsRes.items) {
        final hex = _pubkeyHex(item.friendPublicKey);
        states[hex] = UserDirFriendState(
          peerPubkey: item.friendPublicKey,
          status: UserDirFriendStatus.friend,
        );
      }

      _incomingRequestIds.clear();
      final reqRaw = await _rpc.callRpc(
        'listFriendRequests',
        ListFriendRequestsRequest().toMap(),
      );
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

  Future<String?> _authenticate(
    Uint8List pubkey,
    SimpleKeyPairData keyPair,
  ) async {
    try {
      final challengeReq = RequestAuthChallengeRequest(
        userPublicKey: pubkey,
        publicIp: '',
        deviceId: 'flutter-client',
        clientNonce: _randomBytes(32),
      );
      final challengeRaw =
          await _rpc.callRpc('requestAuthChallenge', challengeReq.toMap());
      final challengeRes = RequestAuthChallengeResponse.fromMap(challengeRaw);

      final algorithm = Ed25519();
      final sig = await algorithm.sign(
        challengeRes.challengePayload,
        keyPair: keyPair,
      );

      final solveReq = SolveAuthChallengeRequest(
        sessionId: challengeRes.sessionId,
        signature: Uint8List.fromList(sig.bytes),
      );
      final solveRaw =
          await _rpc.callRpc('solveAuthChallenge', solveReq.toMap());
      final solveRes = SolveAuthChallengeResponse.fromMap(solveRaw);

      if (!solveRes.isAuthenticated) {
        return 'Authentication rejected by server';
      }

      _rpc.setCredentials(pubkey, keyPair);
      AppLogger.d('Authenticated as ${_hexShort(pubkey)}', tag: _tag);
      return null;
    } catch (e) {
      return 'Authentication failed: $e';
    }
  }

  void _ensureCredentials(Uint8List pubkey, SimpleKeyPairData keyPair) {
    if (!_rpc.hasCredentials) {
      _rpc.setCredentials(pubkey, keyPair);
    }
  }

  static UserDirMeta _profileToMeta(ProfileData p) => UserDirMeta(
        pubkey: p.publicKey,
        username: p.username,
        fullname: (p.displayName?.isNotEmpty == true)
            ? p.displayName!
            : p.username,
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

  static final _rng = Random.secure();

  static Uint8List _randomBytes(int length) {
    final bytes = Uint8List(length);
    for (int i = 0; i < length; i++) bytes[i] = _rng.nextInt(256);
    return bytes;
  }
}
