import 'dart:async';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'package:sgtp_flutter/core/app_log.dart';
import 'package:sgtp_flutter/core/network/sgtp_rpc_client.dart';
import 'package:sgtp_flutter/core/network/rpc_models/profile_rpc_models.dart';
import 'package:sgtp_flutter/core/network/rpc_models/friend_rpc_models.dart';
import 'package:sgtp_flutter/core/network/rpc_models/friend_request_rpc_models.dart';
import 'package:sgtp_flutter/core/network/rpc_models/rpc_enums.dart';
import 'package:sgtp_flutter/core/network/rpc_models/rpc_request.dart';
import 'package:sgtp_flutter/features/contacts/domain/repositories/i_user_dir_client.dart';

export 'package:sgtp_flutter/features/contacts/domain/repositories/i_user_dir_client.dart';

class UserDirClient implements IUserDirClient {
  final Future<SgtpRpcClient> Function() _rpcProvider;
  final bool _providerManagesConnection;
  final String? _authDeviceId;
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
  final Map<String, String> _incomingPeersByRequestId = <String, String>{};
  final Map<String, Uint8List> _outgoingRequestIds = {};
  final Map<String, String> _outgoingPeersByRequestId = <String, String>{};
  void Function()? _removeEventsCallback;
  SgtpRpcClient? _eventsRpc;

  final _log = AppLog('UserDirClient');

  UserDirClient({
    required Future<SgtpRpcClient> Function() rpcProvider,
    required this.label,
    bool providerManagesConnection = false,
    String? authDeviceId,
  }) : _rpcProvider = rpcProvider,
       _providerManagesConnection = providerManagesConnection,
       _authDeviceId = authDeviceId;

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
    await _resolveRpcConnected();
    _connected = true;
    _log.debug('Connected via {label}', parameters: {'label': label});
  }

  @override
  void close() {
    _connected = false;
    _removeEventsCallback?.call();
    _removeEventsCallback = null;
    _eventsRpc = null;
    _rpc = null;
  }

  // ── Auth + profile ─��─────────────────────────────────────────────────────

  @override
  Future<({bool ok, String? errorMessage})> registerWithResult({
    required String username,
    required String fullname,
    required Uint8List pubkey,
    required Uint8List avatarBytes,
    required SimpleKeyPairData identityKeyPair,
    String? deviceId,
  }) async {
    try {
      final rpc = await _resolveRpcConnected();
      final authError = await rpc.authenticate(
        pubkey,
        identityKeyPair,
        deviceId: deviceId ?? _authDeviceId ?? 'flutter-client',
      );
      if (authError != null) return (ok: false, errorMessage: authError);

      final req = UpdateProfileRequest(
        username: username.trim().isEmpty ? null : username.trim(),
        displayName: fullname.trim().isEmpty ? null : fullname.trim(),
      );
      final raw = await rpc.callRpc(req);
      UpdateProfileResponse.fromMap(raw);
      _log.debug(
        'Profile updated for {pubkey}',
        parameters: {'pubkey': _hexShort(pubkey)},
      );
      return (ok: true, errorMessage: null);
    } catch (e) {
      _log.error(
        'registerWithResult failed: {error}',
        parameters: {'error': e},
      );
      return (ok: false, errorMessage: e.toString());
    }
  }

  @override
  Future<UserDirMeta?> getMeta(Uint8List pubkey) async {
    try {
      final rpc = await _resolveRpcConnected();
      final req = GetProfileRequest(userPublicKey: pubkey);
      final raw = await rpc.callRpc(req);
      final res = GetProfileResponse.fromMap(raw);
      return _profileToMeta(res.profile);
    } catch (e) {
      _log.warning(
        'getMeta failed for {pubkey}: {error}',
        parameters: {'pubkey': _hexShort(pubkey), 'error': e},
      );
      return null;
    }
  }

  @override
  Future<UserDirProfile?> getProfile(Uint8List pubkey) async {
    try {
      final rpc = await _resolveRpcConnected();
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
      _log.warning(
        'getProfile failed for {pubkey}: {error}',
        parameters: {'pubkey': _hexShort(pubkey), 'error': e},
      );
      return null;
    }
  }

  @override
  Future<List<UserDirMeta>> search(String query, {int limit = 20}) async {
    try {
      final rpc = await _resolveRpcConnected();
      final req = SearchProfilesRequest(query: query, limit: limit);
      final raw = await rpc.callRpc(req);
      final res = SearchProfilesResponse.fromMap(raw);
      return res.items.map(_searchItemToMeta).toList();
    } catch (e) {
      _log.warning(
        'search failed for "{query}": {error}',
        parameters: {'query': query, 'error': e},
      );
      return [];
    }
  }

  @override
  Future<bool> subscribe(List<Uint8List> pubkeys) async {
    try {
      final rpc = await _resolveRpcConnected();
      _ensureEventsCallbackAttached(rpc);
      await rpc.ensureEventsSubscribed(
        requestedAtUs: DateTime.now().microsecondsSinceEpoch,
      );
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
      final rpc = await _resolveRpcConnected();
      final req = SendFriendRequestRequest(receiverPublicKey: peerPubkey);
      final raw = await rpc.callRpc(req);
      final response = SendFriendRequestResponse.fromMap(raw);
      _rememberOutgoingRequest(peerPubkey, response.requestId);
      return true;
    } catch (e) {
      _log.warning(
        'sendFriendRequest failed: {error}',
        parameters: {'error': e},
      );
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
      _log.warning(
        'sendFriendResponse: no cached requestId for {requester} — syncing',
        parameters: {'requester': requesterHex},
      );
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
      final rpc = await _resolveRpcConnected();
      if (accept) {
        await rpc.callRpc(AcceptFriendRequestRequest(requestId: requestId));
      } else {
        await rpc.callRpc(DeclineFriendRequestRequest(requestId: requestId));
      }
      _forgetIncomingRequestById(requestId);
      return true;
    } catch (e) {
      _log.warning(
        'friendResponse(accept={accept}) failed: {error}',
        parameters: {'accept': accept, 'error': e},
      );
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
      final rpc = await _resolveRpcConnected();
      final req = RemoveFriendRequest(friendPublicKey: peerPubkey);
      await rpc.callRpc(req);
      return true;
    } catch (e) {
      _log.warning(
        'sendFriendDelete failed: {error}',
        parameters: {'error': e},
      );
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
      final rpc = await _resolveRpcConnected();

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

      _outgoingRequestIds.clear();
      _incomingPeersByRequestId.clear();
      _outgoingPeersByRequestId.clear();
      for (final item in reqRes.items) {
        if (item.state != FriendRequestStateEnum.pending) continue;
        final senderHex = _pubkeyHex(item.senderPublicKey);
        final receiverHex = _pubkeyHex(item.receiverPublicKey);

        if (receiverHex == myHex) {
          _rememberIncomingRequest(item.senderPublicKey, item.requestId);
          states.putIfAbsent(
            senderHex,
            () => UserDirFriendState(
              peerPubkey: item.senderPublicKey,
              status: UserDirFriendStatus.pendingIncoming,
            ),
          );
        } else if (senderHex == myHex) {
          _rememberOutgoingRequest(item.receiverPublicKey, item.requestId);
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
    fullname: (p.displayName?.isNotEmpty == true) ? p.displayName! : p.username,
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

  Future<SgtpRpcClient> _resolveRpcConnected() async {
    final rpc = await _resolveRpc();
    if (!rpc.transport.isConnected) {
      if (_providerManagesConnection) {
        _removeEventsCallback?.call();
        _removeEventsCallback = null;
        _eventsRpc = null;
        _rpc = null;
        final refreshed = await _resolveRpc();
        _ensureEventsCallbackAttached(refreshed);
        return refreshed;
      }
      await rpc.transport.connect();
    }
    _ensureEventsCallbackAttached(rpc);
    return rpc;
  }

  void _ensureEventsCallbackAttached(SgtpRpcClient rpc) {
    if (identical(_eventsRpc, rpc) && _removeEventsCallback != null) {
      return;
    }
    _removeEventsCallback?.call();
    _removeEventsCallback = rpc.registerEventsCallback(_handleServerEvent);
    _eventsRpc = rpc;
  }

  void _handleServerEvent(Map<String, dynamic> event) {
    final eventType = event['eventType'] as String?;
    final parameters = event['parameters'];
    if (eventType == null || parameters is! Map<String, dynamic>) {
      return;
    }

    switch (eventType) {
      case 'profile.updated':
        final meta = _tryParseProfileUpdate(parameters);
        if (meta != null) {
          _notifyCtrl.add(meta);
        }
        break;
      case 'friend.requestReceived':
        final requestId = _parseUuidBytes(parameters['requestId']);
        final senderPublicKey = _parseBytes(parameters['senderPublicKey']);
        if (requestId == null || senderPublicKey == null) {
          return;
        }
        _rememberIncomingRequest(senderPublicKey, requestId);
        _friendNotifyCtrl.add(
          UserDirFriendNotify(
            eventType: UserDirFriendEventType.requestReceived,
            status: UserDirFriendStatus.pendingIncoming,
            peerPubkey: senderPublicKey,
            requestId: requestId,
          ),
        );
        break;
      case 'friend.requestAccepted':
        final requestId = _parseUuidBytes(parameters['requestId']);
        final friendPublicKey = _parseBytes(parameters['friendPublicKey']);
        if (friendPublicKey == null) {
          return;
        }
        if (requestId != null) {
          _forgetOutgoingRequestById(requestId);
        } else {
          _outgoingRequestIds.remove(_pubkeyHex(friendPublicKey));
        }
        _friendNotifyCtrl.add(
          UserDirFriendNotify(
            eventType: UserDirFriendEventType.requestAccepted,
            status: UserDirFriendStatus.friend,
            peerPubkey: friendPublicKey,
            requestId: requestId,
          ),
        );
        break;
      case 'friend.requestDeclined':
        final requestId = _parseUuidBytes(parameters['requestId']);
        final peerPubkey = requestId == null
            ? null
            : _lookupOutgoingPeerPublicKeyByRequestId(requestId);
        if (requestId != null) {
          _forgetOutgoingRequestById(requestId);
        }
        _friendNotifyCtrl.add(
          UserDirFriendNotify(
            eventType: UserDirFriendEventType.requestDeclined,
            status: UserDirFriendStatus.rejected,
            peerPubkey: peerPubkey,
            requestId: requestId,
          ),
        );
        break;
      case 'friend.requestCanceled':
        final requestId = _parseUuidBytes(parameters['requestId']);
        final peerPubkey = requestId == null
            ? null
            : _lookupIncomingPeerPublicKeyByRequestId(requestId);
        if (requestId != null) {
          _forgetIncomingRequestById(requestId);
        }
        _friendNotifyCtrl.add(
          UserDirFriendNotify(
            eventType: UserDirFriendEventType.requestCanceled,
            status: UserDirFriendStatus.none,
            peerPubkey: peerPubkey,
            requestId: requestId,
          ),
        );
        break;
    }
  }

  UserDirMeta? _tryParseProfileUpdate(Map<String, dynamic> parameters) {
    final publicKey = _parseBytes(parameters['userPublicKey']);
    if (publicKey == null) {
      return null;
    }
    final username = (parameters['username'] as String? ?? '').trim();
    final displayName = (parameters['displayName'] as String? ?? '').trim();
    final updatedAt = parseTimestampUs(parameters['updatedAt']) ~/ 1000000;
    return UserDirMeta(
      pubkey: publicKey,
      username: username,
      fullname: displayName.isNotEmpty
          ? displayName
          : (username.isNotEmpty ? username : 'Account'),
      avatarSha256: Uint8List(0),
      updatedAt: updatedAt,
    );
  }

  void _rememberIncomingRequest(Uint8List peerPubkey, Uint8List requestId) {
    final peerHex = _pubkeyHex(peerPubkey);
    final requestHex = _uuidHex(requestId);
    _incomingRequestIds[peerHex] = Uint8List.fromList(requestId);
    _incomingPeersByRequestId[requestHex] = peerHex;
  }

  void _rememberOutgoingRequest(Uint8List peerPubkey, Uint8List requestId) {
    final peerHex = _pubkeyHex(peerPubkey);
    final requestHex = _uuidHex(requestId);
    _outgoingRequestIds[peerHex] = Uint8List.fromList(requestId);
    _outgoingPeersByRequestId[requestHex] = peerHex;
  }

  void _forgetIncomingRequestById(Uint8List requestId) {
    final requestHex = _uuidHex(requestId);
    final peerHex = _incomingPeersByRequestId.remove(requestHex);
    if (peerHex != null) {
      _incomingRequestIds.remove(peerHex);
    }
  }

  void _forgetOutgoingRequestById(Uint8List requestId) {
    final requestHex = _uuidHex(requestId);
    final peerHex = _outgoingPeersByRequestId.remove(requestHex);
    if (peerHex != null) {
      _outgoingRequestIds.remove(peerHex);
    }
  }

  Uint8List? _lookupIncomingPeerPublicKeyByRequestId(Uint8List requestId) {
    final peerHex = _incomingPeersByRequestId[_uuidHex(requestId)];
    if (peerHex == null) {
      return null;
    }
    return _hexToBytes(peerHex);
  }

  Uint8List? _lookupOutgoingPeerPublicKeyByRequestId(Uint8List requestId) {
    final peerHex = _outgoingPeersByRequestId[_uuidHex(requestId)];
    if (peerHex == null) {
      return null;
    }
    return _hexToBytes(peerHex);
  }

  static Uint8List? _parseBytes(dynamic value) {
    if (value is Uint8List) {
      return Uint8List.fromList(value);
    }
    if (value is List<int>) {
      return Uint8List.fromList(value);
    }
    if (value is String) {
      final normalized = value.trim().replaceAll('-', '');
      if (normalized.isEmpty || normalized.length.isOdd) {
        return null;
      }
      try {
        return _hexToBytes(normalized);
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  static Uint8List? _parseUuidBytes(dynamic value) {
    final bytes = _parseBytes(value);
    if (bytes == null || bytes.length != 16) {
      return null;
    }
    return bytes;
  }

  static String _uuidHex(Uint8List bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  static Uint8List _hexToBytes(String hex) {
    final out = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < hex.length; i += 2) {
      out[i ~/ 2] = int.parse(hex.substring(i, i + 2), radix: 16);
    }
    return out;
  }
}
