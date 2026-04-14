import 'dart:async';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'package:sgtp_flutter/core/app_log.dart';
import 'package:sgtp_flutter/core/network/events/sgtp_server_events.dart';
import 'package:sgtp_flutter/core/network/rpc_models/auth_rpc_models.dart';
import 'package:sgtp_flutter/core/network/rpc_models/messaging_rpc_models.dart';
import 'package:sgtp_flutter/core/network/rpc_models/mls_rpc_models.dart';
import 'package:sgtp_flutter/core/network/rpc_models/room_rpc_models.dart';
import 'package:sgtp_flutter/core/network/sgtp_rpc_client.dart';

class ServerV2MlsClient {
  static final Expando<bool> _rpcEventsSubscribed =
      Expando<bool>('rpc_events_subscribed');
  static final Expando<Future<void>> _rpcEventsSubscriptionInFlight =
      Expando<Future<void>>('rpc_events_subscription_in_flight');

  final Future<SgtpRpcClient> Function() _rpcProvider;
  final Stream<Map<String, dynamic>>? _sharedServerEvents;
  final _log = AppLog('ServerV2MlsClient');
  final _events = StreamController<SgtpServerEvent>.broadcast();

  SgtpRpcClient? _rpc;
  bool _connected = false;
  bool _eventsSubscribed = false;
  void Function()? _removeEventsCallback;
  StreamSubscription<Map<String, dynamic>>? _sharedEventsSub;

  ServerV2MlsClient({
    required Future<SgtpRpcClient> Function() rpcProvider,
    Stream<Map<String, dynamic>>? sharedServerEvents,
  })  : _rpcProvider = rpcProvider,
        _sharedServerEvents = sharedServerEvents;

  bool get isConnected => _connected;
  bool get isTransportConnected => _rpc?.transport.isConnected == true;
  Stream<SgtpServerEvent> get events => _events.stream;

  Future<void> connect() async {
    if (_connected) return;
    await _ensureRpc();
    _connected = true;
  }

  Future<String?> authenticate(
    Uint8List publicKey,
    SimpleKeyPairData identityKeyPair, {
    String deviceId = 'flutter-client',
  }) async {
    final rpc = await _ensureRpc();
    return rpc.authenticate(publicKey, identityKeyPair, deviceId: deviceId);
  }

  Future<void> ensureSubscribedToEvents() async {
    if (_eventsSubscribed) return;
    final rpc = await _ensureRpc();
    if (_rpcEventsSubscribed[rpc] == true) {
      _log.debug('Reusing existing server event subscription for shared RPC');
      _eventsSubscribed = true;
      return;
    }
    final existingSubscription = _rpcEventsSubscriptionInFlight[rpc];
    if (existingSubscription != null) {
      _log.debug('Waiting for existing shared server event subscription');
      await existingSubscription;
      _eventsSubscribed = true;
      return;
    }
    _log.info('Subscribing shared RPC to server events');
    final subscription = rpc
        .callRpc(SubscribeToEventsRequest(
      requestedAtUs: DateTime.now().microsecondsSinceEpoch,
    ))
        .then<void>((_) {
      _rpcEventsSubscribed[rpc] = true;
    });
    _rpcEventsSubscriptionInFlight[rpc] = subscription;
    try {
      await subscription;
      _eventsSubscribed = true;
    } finally {
      _rpcEventsSubscriptionInFlight[rpc] = null;
    }
  }

  Future<UploadKeyPackagesResponse> uploadKeyPackages(
      List<KeyPackageDto> packages) async {
    final rpc = await _ensureRpc();
    final raw = await rpc.callRpc(UploadKeyPackagesRequest(packages: packages));
    return UploadKeyPackagesResponse.fromMap(raw);
  }

  Future<FetchKeyPackagesResponse> fetchKeyPackages(
      List<Uint8List> userPublicKeys) async {
    final rpc = await _ensureRpc();
    final raw = await rpc
        .callRpc(FetchKeyPackagesRequest(userPublicKeys: userPublicKeys));
    return FetchKeyPackagesResponse.fromMap(raw);
  }

  Future<SendCommitResponse> sendCommit({
    required String roomId,
    required Uint8List commitBytes,
  }) async {
    final rpc = await _ensureRpc();
    final raw = await rpc.callRpc(
      SendCommitRequest(
        roomId: roomId,
        commitBytes: commitBytes,
      ),
    );
    return SendCommitResponse.fromMap(raw);
  }

  Future<SendWelcomeResponse> sendWelcome({
    String? roomId,
    required Uint8List targetUserPublicKey,
    required Uint8List welcomeBytes,
  }) async {
    final rpc = await _ensureRpc();
    final raw = await rpc.callRpc(
      SendWelcomeRequest(
        roomId: roomId,
        targetUserPublicKey: targetUserPublicKey,
        welcomeBytes: welcomeBytes,
      ),
    );
    return SendWelcomeResponse.fromMap(raw);
  }

  Future<FetchWelcomeResponse> fetchWelcome({
    required String roomId,
  }) async {
    final rpc = await _ensureRpc();
    final raw = await rpc.callRpc(FetchWelcomeRequest(roomId: roomId));
    return FetchWelcomeResponse.fromMap(raw);
  }

  Future<SendMessageResponse> sendMessage({
    required String roomId,
    required Uint8List clientMsgId,
    required List<Uint8List> body,
  }) async {
    final rpc = await _ensureRpc();
    final raw = await rpc.callRpc(
      SendMessageRequest(
        roomId: roomId,
        clientMsgId: clientMsgId,
        body: body,
      ),
    );
    return SendMessageResponse.fromMap(raw);
  }

  Future<DeleteMessageResponse> deleteMessage({
    required String roomId,
    required String messageId,
  }) async {
    final rpc = await _ensureRpc();
    final raw = await rpc.callRpc(
      DeleteMessageRequest(
        roomId: roomId,
        messageId: messageId,
      ),
    );
    return DeleteMessageResponse.fromMap(raw);
  }

  Future<CreateChatRoomResponse> createChatRoom({
    String? title,
    String? description,
    int visibility = 3,
  }) async {
    final rpc = await _ensureRpc();
    final raw = await rpc.callRpc(
      CreateChatRoomRequest(
        title: title,
        description: description,
        visibility: visibility,
      ),
    );
    return CreateChatRoomResponse.fromMap(raw);
  }

  Future<ListChatRoomsResponse> listChatRooms({
    int? limit,
    String? cursor,
  }) async {
    final rpc = await _ensureRpc();
    final raw = await rpc.callRpc(
      ListChatRoomsRequest(limit: limit, cursor: cursor),
    );
    return ListChatRoomsResponse.fromMap(raw);
  }

  Future<GetChatRoomResponse> getChatRoom(String roomId) async {
    final rpc = await _ensureRpc();
    final raw = await rpc.callRpc(GetChatRoomRequest(roomId: roomId));
    return GetChatRoomResponse.fromMap(raw);
  }

  Future<SendChatInvitationResponse> sendChatInvitation({
    required String roomId,
    required Uint8List inviteePublicKey,
  }) async {
    final rpc = await _ensureRpc();
    final raw = await rpc.callRpc(
      SendChatInvitationRequest(
        roomId: roomId,
        inviteePublicKey: inviteePublicKey,
      ),
    );
    return SendChatInvitationResponse.fromMap(raw);
  }

  Future<ListIncomingChatInvitationsResponse> listIncomingChatInvitations({
    int? limit,
    String? cursor,
  }) async {
    final rpc = await _ensureRpc();
    final raw = await rpc.callRpc(
      ListIncomingChatInvitationsRequest(limit: limit, cursor: cursor),
    );
    return ListIncomingChatInvitationsResponse.fromMap(raw);
  }

  Future<AcceptChatInvitationResponse> acceptChatInvitation(
    String invitationId, {
    Uint8List? commitBytes,
  }) async {
    final rpc = await _ensureRpc();
    final raw = await rpc.callRpc(
      AcceptChatInvitationRequest(
        invitationId: invitationId,
        commitBytes: commitBytes,
      ),
    );
    return AcceptChatInvitationResponse.fromMap(raw);
  }

  Future<UpdateChatRoomStateResponse> updateChatRoomState({
    required String roomId,
    required String groupId,
    required int epoch,
    required Uint8List treeBytes,
    required Uint8List treeHash,
  }) async {
    final rpc = await _ensureRpc();
    final raw = await rpc.callRpc(
      UpdateChatRoomStateRequest(
        roomId: roomId,
        groupId: groupId,
        epoch: epoch,
        treeBytes: treeBytes,
        treeHash: treeHash,
      ),
    );
    return UpdateChatRoomStateResponse.fromMap(raw);
  }

  Future<FetchChatRoomStateResponse> fetchChatRoomState({
    required String roomId,
    required int epoch,
  }) async {
    final rpc = await _ensureRpc();
    final raw = await rpc.callRpc(
      FetchChatRoomStateRequest(
        roomId: roomId,
        epoch: epoch,
      ),
    );
    return FetchChatRoomStateResponse.fromMap(raw);
  }

  Future<void> close() async {
    _connected = false;
    _eventsSubscribed = false;
    _removeEventsCallback?.call();
    _removeEventsCallback = null;
    await _sharedEventsSub?.cancel();
    _sharedEventsSub = null;
    _rpc = null;
    await _events.close();
  }

  Future<SgtpRpcClient> _ensureRpc() async {
    final existing = _rpc;
    if (existing != null) return existing;
    final rpc = await _rpcProvider();
    final sharedServerEvents = _sharedServerEvents;
    if (sharedServerEvents != null) {
      await _sharedEventsSub?.cancel();
      _sharedEventsSub = sharedServerEvents.listen(_handleEventPacket);
      _log.debug('Listening to shared server event router');
    } else {
      _removeEventsCallback?.call();
      _removeEventsCallback = rpc.registerEventsCallback(_handleEventPacket);
      _log.debug('Registered direct server event callback');
    }
    _rpc = rpc;
    return rpc;
  }

  void _handleEventPacket(Map<String, dynamic> event) {
    final eventType = event['eventType'] as String?;
    final parameters = event['parameters'];
    if (eventType == null || parameters is! Map<String, dynamic>) {
      return;
    }

    switch (eventType) {
      case 'mlsCommitReceived':
        _events.add(MlsCommitReceivedNetworkEvent.fromParameters(parameters));
        break;
      case 'mlsWelcomeReceived':
        _events.add(MlsWelcomeReceivedNetworkEvent.fromParameters(parameters));
        break;
      case 'mlsExternalCommitReceived':
        _events.add(
          MlsExternalCommitReceivedNetworkEvent.fromParameters(parameters),
        );
        break;
      case 'mlsMessageReceived':
        _events.add(MlsMessageReceivedNetworkEvent.fromParameters(parameters));
        break;
      default:
        _log.debug('Ignoring server event: {eventType}',
            parameters: {'eventType': eventType});
    }
  }
}
