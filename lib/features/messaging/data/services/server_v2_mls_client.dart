import 'dart:async';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'package:sgtp_flutter/core/app_log.dart';
import 'package:sgtp_flutter/core/network/rpc_models/auth_rpc_models.dart';
import 'package:sgtp_flutter/core/network/rpc_models/messaging_rpc_models.dart';
import 'package:sgtp_flutter/core/network/rpc_models/mls_rpc_models.dart';
import 'package:sgtp_flutter/core/network/rpc_models/overview_rpc_models.dart';
import 'package:sgtp_flutter/core/network/rpc_models/room_rpc_models.dart';
import 'package:sgtp_flutter/core/network/sgtp_rpc_client.dart';

sealed class ServerV2MlsEvent {
  const ServerV2MlsEvent();
}

class ServerV2MlsCommitReceived extends ServerV2MlsEvent {
  final MlsCommitReceivedEvent event;

  const ServerV2MlsCommitReceived(this.event);
}

class ServerV2MlsWelcomeReceived extends ServerV2MlsEvent {
  final MlsWelcomeReceivedEvent event;

  const ServerV2MlsWelcomeReceived(this.event);
}

class ServerV2MlsMessageReceived extends ServerV2MlsEvent {
  final MlsMessageReceivedEvent event;

  const ServerV2MlsMessageReceived(this.event);
}

class ServerV2MlsClient {
  final SgtpRpcClient _rpc;
  final _log = AppLog('ServerV2MlsClient');
  final _events = StreamController<ServerV2MlsEvent>.broadcast();

  bool _connected = false;
  bool _eventsSubscribed = false;

  ServerV2MlsClient({required SgtpRpcClient rpc}) : _rpc = rpc {
    _rpc.registerEventsCallback(_handleEventPacket);
  }

  bool get isConnected => _connected;
  Stream<ServerV2MlsEvent> get events => _events.stream;

  Future<void> connect() async {
    if (_connected) return;
    await _rpc.transport.connect();
    _connected = true;
  }

  Future<String?> authenticate(
    Uint8List publicKey,
    SimpleKeyPairData identityKeyPair, {
    String deviceId = 'flutter-client',
  }) =>
      _rpc.authenticate(publicKey, identityKeyPair, deviceId: deviceId);

  Future<void> ensureSubscribedToEvents() async {
    if (_eventsSubscribed) return;
    await _rpc.callRpc(SubscribeToEventsRequest(
      requestedAtUs: DateTime.now().microsecondsSinceEpoch,
    ));
    _eventsSubscribed = true;
  }

  Future<UploadKeyPackagesResponse> uploadKeyPackages(
      List<KeyPackageDto> packages) async {
    final raw =
        await _rpc.callRpc(UploadKeyPackagesRequest(packages: packages));
    return UploadKeyPackagesResponse.fromMap(raw);
  }

  Future<FetchKeyPackagesResponse> fetchKeyPackages(
      List<Uint8List> userPublicKeys) async {
    final raw = await _rpc
        .callRpc(FetchKeyPackagesRequest(userPublicKeys: userPublicKeys));
    return FetchKeyPackagesResponse.fromMap(raw);
  }

  Future<SendCommitResponse> sendCommit({
    required String roomId,
    required Uint8List commitBytes,
  }) async {
    final raw = await _rpc.callRpc(
      SendCommitRequest(
        roomId: roomId,
        commitBytes: commitBytes,
      ),
    );
    return SendCommitResponse.fromMap(raw);
  }

  Future<SendWelcomeResponse> sendWelcome({
    required Uint8List targetUserPublicKey,
    required Uint8List welcomeBytes,
  }) async {
    final raw = await _rpc.callRpc(
      SendWelcomeRequest(
        targetUserPublicKey: targetUserPublicKey,
        welcomeBytes: welcomeBytes,
      ),
    );
    return SendWelcomeResponse.fromMap(raw);
  }

  Future<SendMessageResponse> sendMessage({
    required String roomId,
    required Uint8List clientMsgId,
    required List<Uint8List> body,
  }) async {
    final raw = await _rpc.callRpc(
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
    final raw = await _rpc.callRpc(
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
    final raw = await _rpc.callRpc(
      CreateChatRoomRequest(
        title: title,
        description: description,
        visibility: visibility,
      ),
    );
    return CreateChatRoomResponse.fromMap(raw);
  }

  Future<GetChatRoomResponse> getChatRoom(String roomId) async {
    final raw = await _rpc.callRpc(GetChatRoomRequest(roomId: roomId));
    return GetChatRoomResponse.fromMap(raw);
  }

  Future<SendChatInvitationResponse> sendChatInvitation({
    required String roomId,
    required Uint8List inviteePublicKey,
  }) async {
    final raw = await _rpc.callRpc(
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
    final raw = await _rpc.callRpc(
      ListIncomingChatInvitationsRequest(limit: limit, cursor: cursor),
    );
    return ListIncomingChatInvitationsResponse.fromMap(raw);
  }

  Future<AcceptChatInvitationResponse> acceptChatInvitation(
      String invitationId) async {
    final raw = await _rpc.callRpc(
      AcceptChatInvitationRequest(invitationId: invitationId),
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
    final raw = await _rpc.callRpc(
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

  Future<void> pollEvents() async {
    await _rpc.callRpc(const GetServerConfigRequest());
  }

  Future<void> close() async {
    _connected = false;
    await _rpc.transport.close();
    await _events.close();
  }

  void _handleEventPacket(Map<String, dynamic> event) {
    final eventType = event['eventType'] as String?;
    final parameters = event['parameters'];
    if (eventType == null || parameters is! Map<String, dynamic>) {
      return;
    }

    switch (eventType) {
      case 'mlsCommitReceived':
        _events.add(ServerV2MlsCommitReceived(
          MlsCommitReceivedEvent.fromParameters(parameters),
        ));
        break;
      case 'mlsWelcomeReceived':
        _events.add(ServerV2MlsWelcomeReceived(
          MlsWelcomeReceivedEvent.fromParameters(parameters),
        ));
        break;
      case 'mlsMessageReceived':
        _events.add(ServerV2MlsMessageReceived(
          MlsMessageReceivedEvent.fromParameters(parameters),
        ));
        break;
      default:
        _log.debug('Ignoring server event: {eventType}',
            parameters: {'eventType': eventType});
    }
  }
}
