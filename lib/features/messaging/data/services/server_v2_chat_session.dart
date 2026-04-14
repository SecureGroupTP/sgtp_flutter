import 'dart:async';
import 'dart:convert' show base64, json, utf8;
import 'dart:math';
import 'dart:typed_data';

import 'package:cross_file/cross_file.dart';
import 'package:sgtp_chat_core/sgtp_chat_core.dart';

import 'package:sgtp_flutter/core/app_log.dart';
import 'package:sgtp_flutter/core/network/events/sgtp_server_events.dart';
import 'package:sgtp_flutter/core/network/rpc_models/rpc_enums.dart';
import 'package:sgtp_flutter/core/network/sgtp_connection_service.dart';
import 'package:sgtp_flutter/core/uuid_v7.dart';
import 'package:sgtp_flutter/features/messaging/data/repositories/chat_metadata_repository.dart';
import 'package:sgtp_flutter/features/messaging/data/services/server_v2_mls_client.dart';
import 'package:sgtp_flutter/features/messaging/domain/entities/chat_metadata.dart';
import 'package:sgtp_flutter/features/messaging/domain/entities/message.dart';
import 'package:sgtp_flutter/features/messaging/domain/entities/peer.dart';
import 'package:sgtp_flutter/features/messaging/domain/entities/sgtp_config.dart';
import 'package:sgtp_flutter/features/messaging/domain/entities/video_note_metadata.dart';
import 'package:sgtp_flutter/features/messaging/domain/repositories/i_sgtp_session.dart';

final _log = AppLog('ServerV2ChatSession');

class _PendingMedia {
  final String id;
  final String type;
  final String name;
  final String mime;
  final int chunks;
  final String senderUUID;
  final String? senderPublicKeyHex;
  final VideoNoteMetadata? videoNoteMetadata;
  final List<Uint8List?> parts;

  _PendingMedia({
    required this.id,
    required this.type,
    required this.name,
    required this.mime,
    required this.chunks,
    required this.senderUUID,
    required this.senderPublicKeyHex,
    required this.videoNoteMetadata,
  }) : parts = List<Uint8List?>.filled(chunks, null);

  void put(int index, Uint8List bytes) {
    if (index >= 0 && index < parts.length) {
      parts[index] = bytes;
    }
  }

  bool get isComplete => parts.every((item) => item != null);

  Uint8List assemble() {
    final builder = BytesBuilder(copy: false);
    for (final item in parts) {
      if (item != null) {
        builder.add(item);
      }
    }
    return builder.takeBytes();
  }
}

class ServerV2ChatSession implements ISgtpSession {
  final SgtpConfig _config;
  final SgtpConnectionService _connectionService;
  final _eventController = StreamController<SgtpEvent>.broadcast();
  final Map<String, PeerInfo> _peers = {};
  final Map<String, String> _peerPublicKeys = {};
  final Map<String, _PendingMedia> _pendingMedia = {};
  final Set<String> _invitedPeerDevices = {};
  final ChatMetadataRepository? _metadataRepository;
  Set<String> _whitelist;

  MessengerMls? _mls;
  ServerV2MlsClient? _rpcChat;
  StreamSubscription<SgtpServerEvent>? _rpcEventSub;
  Timer? _inviteRetryTimer;
  Timer? _remoteRoomBindRetryTimer;
  Future<void>? _pendingRemoteRoomBind;
  bool _mlsClientReady = false;
  bool _mlsGroupReady = false;
  bool _mlsGroupCreated = false;
  bool _connecting = false;
  bool _connected = false;
  bool _readyEmitted = false;
  bool _isDirectRoom = false;
  bool _directRoomNeedsBootstrap = false;
  String? _remoteRoomId;
  Uint8List? _userAvatarBytes;
  late final Uint8List _roomUUID;
  late final String _deviceId;

  ServerV2ChatSession(
    SgtpConfig config, {
    required SgtpConnectionService connectionService,
  })  : _config = config,
        _connectionService = connectionService,
        _whitelist = _normalizeWhitelist(config.whitelist),
        _metadataRepository = (config.accountId ?? '').trim().isEmpty
            ? null
            : ChatMetadataRepository(accountId: config.accountId) {
    _isDirectRoom = config.isDirectMessage;
    _directRoomNeedsBootstrap = config.bootstrapDirectRoom;
    _roomUUID = config.roomUUID.every((b) => b == 0)
        ? generateUUIDv7()
        : Uint8List.fromList(config.roomUUID);
    _deviceId = 'flutter-${_hex(config.myPublicKey).substring(0, 16)}';
  }

  @override
  Stream<SgtpEvent> get events => _eventController.stream;

  @override
  String get roomUUIDHex => uuidBytesToHex(_roomUUID);

  @override
  String get myUUIDHex => _hex(_config.myPublicKey);

  @override
  List<String> get peerUUIDs => _peers.keys.toList(growable: false);

  @override
  Map<String, String> get peerPublicKeys => Map.unmodifiable(_peerPublicKeys);

  bool get _isMaster {
    final all = <String>{myUUIDHex, ..._whitelist}.toList()..sort();
    return all.isNotEmpty && all.first == myUUIDHex;
  }

  Map<String, dynamic> get _mlsGroupIdJson => {'value': _roomUUID};

  @override
  Future<void> connect() async {
    if (_connecting || _connected) return;
    _connecting = true;
    _eventController.add(SgtpConnecting());
    _eventController.add(SgtpHandshaking());
    try {
      await _initMls();
      await _loadRemoteRoomId();
      await _connectRpc();
      _seedKnownPeerPublicKeys();
      await _bootstrapRoomAndMls();
      _scheduleInviteRetry();
      _emitReadyIfNeeded(force: _mlsGroupReady || _whitelist.isEmpty);
    } catch (e) {
      _log.error('connect failed: {error}', parameters: {'error': e});
      _eventController.add(SgtpError(error: 'Connection failed: $e'));
      await disconnect();
    } finally {
      _connecting = false;
    }
  }

  @override
  Future<void> disconnect() async {
    _connected = false;
    _readyEmitted = false;
    _inviteRetryTimer?.cancel();
    _inviteRetryTimer = null;
    _remoteRoomBindRetryTimer?.cancel();
    _remoteRoomBindRetryTimer = null;
    _pendingRemoteRoomBind = null;
    await _rpcEventSub?.cancel();
    _rpcEventSub = null;
    final rpcChat = _rpcChat;
    _rpcChat = null;
    await rpcChat?.close();
    _eventController.add(SgtpDisconnected());
  }

  @override
  Future<void> close() async {
    await disconnect();
    _mls?.close();
    _mls = null;
    _mlsClientReady = false;
    if (!_eventController.isClosed) {
      await _eventController.close();
    }
  }

  @override
  Future<void> probeConnection() async {
    if (!_connected) {
      await connect();
      return;
    }
    final client = _rpcChat;
    if (client == null || !client.isTransportConnected) {
      _log.warning('RPC transport is not connected during probe');
      await disconnect();
    }
  }

  @override
  void setUserAvatar(Uint8List? bytes) {
    _userAvatarBytes = bytes;
  }

  @override
  void updateWhitelist(Set<String> whitelist) {
    _whitelist = _normalizeWhitelist(whitelist);
    _seedKnownPeerPublicKeys();
    if (_connected && _isMaster) {
      unawaited(_inviteKnownPeers());
    }
  }

  @override
  Future<void> sendMessage(
    String text, {
    String? replyToId,
    String? replyToContent,
    String? replyToSender,
  }) async {
    final payload = <String, dynamic>{
      'v': 1,
      'type': 'text',
      'text': text,
      'pub': myUUIDHex,
      if (replyToId != null) 'reply_to_id': replyToId,
      if (replyToContent != null) 'reply_to_content': replyToContent,
      if (replyToSender != null) 'reply_to_sender': replyToSender,
    };
    _attachSenderAvatar(payload);

    final localId = uuidBytesToHex(generateUUIDv7());
    _eventController.add(
      SgtpMessageReceived(
        message: ChatMessage(
          id: localId,
          senderUUID: myUUIDHex,
          senderPublicKeyHex: myUUIDHex,
          content: text,
          receivedAt: DateTime.now(),
          isFromHistory: false,
          isFromMe: true,
          replyToId: replyToId,
          replyToContent: replyToContent,
          replyToSender: replyToSender,
        ),
      ),
    );
    await _sendPayload(payload);
  }

  @override
  Future<void> sendImage(Uint8List bytes, String name, String mime) {
    return _sendMediaBytes(
      bytes,
      name,
      mime,
      'image',
      echoMessage: ChatMessage(
        id: uuidBytesToHex(generateUUIDv7()),
        senderUUID: myUUIDHex,
        senderPublicKeyHex: myUUIDHex,
        content: name,
        imageBytes: bytes,
        mediaMime: mime,
        mediaName: name,
        type: MessageType.image,
        receivedAt: DateTime.now(),
        isFromHistory: false,
        isFromMe: true,
      ),
    );
  }

  @override
  Future<void> sendVideo(XFile xFile, String name, String mime) async {
    final bytes = await xFile.readAsBytes();
    await _sendMediaBytes(
      bytes,
      name,
      mime,
      'video',
      echoMessage: ChatMessage(
        id: uuidBytesToHex(generateUUIDv7()),
        senderUUID: myUUIDHex,
        senderPublicKeyHex: myUUIDHex,
        content: name,
        videoBytes: bytes,
        mediaMime: mime,
        mediaName: name,
        type: MessageType.video,
        receivedAt: DateTime.now(),
        isFromHistory: false,
        isFromMe: true,
      ),
    );
  }

  @override
  Future<void> sendVoice(Uint8List bytes, String mime) {
    return _sendMediaBytes(
      bytes,
      'voice',
      mime,
      'voice',
      echoMessage: ChatMessage(
        id: uuidBytesToHex(generateUUIDv7()),
        senderUUID: myUUIDHex,
        senderPublicKeyHex: myUUIDHex,
        content: 'voice',
        audioBytes: bytes,
        mediaMime: mime,
        mediaName: 'voice',
        type: MessageType.voice,
        receivedAt: DateTime.now(),
        isFromHistory: false,
        isFromMe: true,
      ),
    );
  }

  @override
  Future<void> sendVideoNote(Uint8List bytes, String mime) {
    return _sendMediaBytes(bytes, 'video_note', mime, 'video_note');
  }

  @override
  Future<void> sendVideoNoteFromXFile(
    XFile xFile,
    String mime, {
    VideoNoteMetadata? metadata,
  }) async {
    final bytes = await xFile.readAsBytes();
    await _sendMediaBytes(
      bytes,
      xFile.name,
      mime,
      'video_note',
      extraPayload: metadata?.toPayloadJson(),
      echoMessage: ChatMessage(
        id: uuidBytesToHex(generateUUIDv7()),
        senderUUID: myUUIDHex,
        senderPublicKeyHex: myUUIDHex,
        content: xFile.name,
        videoBytes: bytes,
        mediaMime: mime,
        mediaName: xFile.name,
        videoNoteMetadata: metadata,
        type: MessageType.videoNote,
        receivedAt: DateTime.now(),
        isFromHistory: false,
        isFromMe: true,
      ),
    );
  }

  @override
  Future<void> sendMessageRead(String messageId) {
    return _sendPayload({
      'v': 1,
      'type': 'message_read',
      'msg_id': messageId,
      'pub': myUUIDHex,
    });
  }

  @override
  void sendReaction(String messageId, String emoji, bool adding) {
    unawaited(_sendPayload({
      'v': 1,
      'type': 'reaction',
      'msg_id': messageId,
      'emoji': emoji,
      'add': adding,
      'pub': myUUIDHex,
    }));
  }

  @override
  Future<void> sendChatMeta(String name, Uint8List? avatarBytes) {
    return _sendPayload({
      'v': 1,
      'type': 'chat_meta',
      'name': name,
      if (avatarBytes != null && avatarBytes.isNotEmpty)
        'avatar': base64.encode(avatarBytes),
      'pub': myUUIDHex,
    });
  }

  @override
  Future<PersistedHistoryBatchResult> replayPersistedHistoryBatch({
    required int offsetFromEnd,
    required int limit,
  }) async {
    return const PersistedHistoryBatchResult(loaded: 0, total: 0);
  }

  Future<void> _connectRpc() async {
    final client = ServerV2MlsClient(
      rpcProvider: () => _connectionService.acquireRpc(_config),
      sharedServerEvents: _connectionService.serverEvents,
    );
    _rpcEventSub = client.events.listen(
      _handleServerEvent,
      onError: (Object e) =>
          _eventController.add(SgtpError(error: 'Server event error: $e')),
    );
    await client.connect();
    await client.ensureSubscribedToEvents();
    _rpcChat = client;
    _connected = true;
  }

  Future<void> _initMls() async {
    if (_mlsClientReady) return;
    final privateKey = await _config.identityKeyPair.extractPrivateKeyBytes();
    final userId =
        (_config.accountId ?? _config.nodeId ?? _hex(_config.myPublicKey))
            .trim();
    final clientId = {
      'user_id': userId.isEmpty ? _hex(_config.myPublicKey) : userId,
      'device_id': _deviceId,
    };
    final mls = MessengerMls.create();
    mls.createClientSync({
      'client_id': clientId,
      'device_signature_private_key': privateKey,
      'binding': {
        'client_id': clientId,
        'serialized_binding': _config.myPublicKey,
        'account_signature': <int>[],
      },
      'identity_data': _config.myPublicKey,
    });
    _mls = mls;
    _mlsClientReady = true;
  }

  Future<void> _bootstrapRoomAndMls() async {
    if (_isDirectRoom) {
      await _bootstrapDirectRoomAndMls();
      return;
    }
    await _ensureRemoteRoomBound();
    if (_isMaster) {
      await _ensureMlsGroupCreated();
      await _publishRoomState();
      await _inviteKnownPeers();
    } else {
      await _joinFromStoredWelcome();
      if (!_mlsGroupReady) {
        if ((_remoteRoomId ?? '').isEmpty) {
          _scheduleRemoteRoomBindRetry();
          _eventController.add(
            SgtpError(
              error:
                  'Waiting for chat invitation from the other participant. Keep this chat open or ask them to open the chat.',
            ),
          );
        }
      }
    }
  }

  Future<void> _bootstrapDirectRoomAndMls() async {
    await _ensureRemoteRoomBound();
    if (_directRoomNeedsBootstrap) {
      await _ensureMlsGroupCreated();
      await _publishRoomState();
      await _inviteKnownPeers();
      _directRoomNeedsBootstrap = false;
      return;
    }
    await _joinFromStoredWelcome();
  }

  Future<void> _ensureRemoteRoomBound() async {
    if ((_remoteRoomId ?? '').isNotEmpty) return;
    final client = _rpcChat;
    if (client == null) return;

    if (_isDirectRoom) {
      final targetUserPublicKey = _directPeerPublicKey;
      if (targetUserPublicKey == null || targetUserPublicKey.isEmpty) {
        throw StateError('Direct room peer public key is missing');
      }
      final created =
          await client.createDirectRoom(targetUserPublicKey: targetUserPublicKey);
      final roomId = _normalizeRoomId(created.roomId);
      if (roomId.isEmpty) {
        throw StateError('Server returned an empty direct room id');
      }
      if (roomId != roomUUIDHex) {
        throw StateError(
          'Direct room id mismatch: local=$roomUUIDHex server=$roomId',
        );
      }
      await _saveRemoteRoomId(roomId);
      _directRoomNeedsBootstrap =
          _directRoomNeedsBootstrap || !created.alreadyExisted;
      return;
    }

    if (_isMaster) {
      final created = await client.createChatRoom(
        title: _config.chatName,
        description: 'sgtp:$roomUUIDHex',
        visibility: 2,
      );
      await _saveRemoteRoomId(created.roomId);
      return;
    }

    final invitations = await client.listIncomingChatInvitations(limit: 100);
    for (final invitation in invitations.items) {
      final invitationState = InvitationStateEnum.fromValue(invitation.state);
      if (invitationState != InvitationStateEnum.pending &&
          invitationState != InvitationStateEnum.accepted) {
        continue;
      }
      final room = await client.getChatRoom(invitation.roomId);
      if ((room.room.description ?? '').trim() == 'sgtp:$roomUUIDHex') {
        if (invitationState == InvitationStateEnum.accepted) {
          await _saveRemoteRoomId(invitation.roomId);
          return;
        }
        if (room.room.visibility == 3) {
          _log.warning(
            'Skipping incompatible private invitation for room {roomId}',
            parameters: {'roomId': invitation.roomId},
          );
          _eventController.add(
            SgtpError(
              error:
                  'Chat invitation cannot be accepted: server rejects private-room invites',
            ),
          );
          return;
        }
        try {
          final accepted =
              await client.acceptChatInvitation(invitation.invitationId);
          await _saveRemoteRoomId(accepted.roomId);
        } catch (e, st) {
          _log.warning(
            'acceptChatInvitation failed for room {roomId}: {error}',
            parameters: {'roomId': invitation.roomId, 'error': e},
            error: e,
            stackTrace: st,
          );
          _eventController.add(
            SgtpError(error: 'Failed to accept chat invitation: $e'),
          );
        }
        return;
      }
    }
  }

  Future<void> _ensureMlsGroupCreated() async {
    if (_mlsGroupCreated) return;
    final mls = _mls;
    if (mls == null) return;
    try {
      mls.createGroupSync(_mlsGroupIdJson);
      _mlsGroupCreated = true;
      _mlsGroupReady = true;
    } on MlsException catch (e) {
      if (!e.message.toLowerCase().contains('exists')) rethrow;
      _mlsGroupCreated = true;
      _mlsGroupReady = true;
    }
  }

  Future<void> _publishRoomState() async {
    final client = _rpcChat;
    final mls = _mls;
    final remoteRoomId = _remoteRoomId;
    if (client == null || mls == null || remoteRoomId == null) return;
    final state = _map(mls.getGroupStateSync(_mlsGroupIdJson));
    final groupId = _asBytes(_map(state['group_id'])['value']);
    final epoch = (state['epoch'] as num?)?.toInt() ?? 0;
    final treeBytes = _asBytes(state['serialized_state']);
    if (groupId.length != 16 || treeBytes.isEmpty) return;
    try {
      await client.updateChatRoomState(
        roomId: remoteRoomId,
        groupId: _uuidString(groupId),
        epoch: epoch,
        treeBytes: treeBytes,
        treeHash: Uint8List(0),
      );
    } on StateError catch (e) {
      if (!_isDuplicateRoomStateError(e)) rethrow;
      _log.debug(
        'Room state already exists for room {roomId} epoch {epoch}; reusing it',
        parameters: {'roomId': remoteRoomId, 'epoch': epoch},
      );
      try {
        final existing = await client.fetchChatRoomState(
          roomId: remoteRoomId,
          epoch: epoch,
        );
        if (existing.groupId.replaceAll('-', '') != _hex(groupId)) {
          _log.warning(
            'Existing room state group differs for room {roomId} epoch {epoch}',
            parameters: {'roomId': remoteRoomId, 'epoch': epoch},
          );
        }
      } catch (_) {}
    }
  }

  bool _isDuplicateRoomStateError(StateError error) {
    final message = error.message.toString();
    return message.contains('duplicate key value') &&
        message.contains('chat_room_states_room_id_epoch_key');
  }

  Future<void> _inviteKnownPeers() async {
    final client = _rpcChat;
    final mls = _mls;
    final remoteRoomId = _remoteRoomId;
    if ((!_isMaster && !_isDirectRoom) ||
        client == null ||
        mls == null ||
        remoteRoomId == null) {
      return;
    }
    final peerHexes = _isDirectRoom
        ? (_config.directPeerPublicKeyHex == null
            ? const <String>[]
            : <String>[_config.directPeerPublicKeyHex!.trim().toLowerCase()])
        : _whitelist.where((item) => item != myUUIDHex).toList();
    if (peerHexes.isEmpty) {
      _emitReadyIfNeeded(force: true);
      return;
    }
    final response = await client.fetchKeyPackages(
      peerHexes.map(hexToBytes).toList(),
    );
    for (final item in response.items) {
      final peerHex = _hex(item.userPublicKey);
      final keyPackageFingerprint = base64.encode(item.keyPackageBytes);
      final peerDeviceKey = '$peerHex:${item.deviceId}:$keyPackageFingerprint';
      if (_invitedPeerDevices.contains(peerDeviceKey)) continue;

      final inviteResult = _map(mls.inviteSync({
        'group_id': _mlsGroupIdJson,
        'invited_client': {
          'user_id': peerHex,
          'device_id': item.deviceId,
        },
        'keypackage': item.keyPackageBytes,
      }));
      final commit = _asBytes(inviteResult['commit_message']);
      final welcome = _asBytes(inviteResult['welcome_message']);

      if (commit.isNotEmpty) {
        await client.sendCommit(roomId: remoteRoomId, commitBytes: commit);
      }
      if (welcome.isNotEmpty) {
        await client.sendWelcome(
          roomId: remoteRoomId,
          targetUserPublicKey: item.userPublicKey,
          welcomeBytes: welcome,
        );
      }
      if (!_isDirectRoom) {
        await client.sendChatInvitation(
          roomId: remoteRoomId,
          inviteePublicKey: item.userPublicKey,
        );
      }
      try {
        mls.mergePendingCommitSync(_mlsGroupIdJson);
      } catch (_) {}
      await _publishRoomState();
      _invitedPeerDevices.add(peerDeviceKey);
    }
    _emitReadyIfNeeded(force: _mlsGroupReady);
  }

  Future<void> _sendPayload(Map<String, dynamic> payload) async {
    final client = _rpcChat;
    final mls = _mls;
    final remoteRoomId = _remoteRoomId;
    if (client == null || mls == null) {
      throw StateError('Chat session is not connected');
    }
    if (remoteRoomId == null || remoteRoomId.isEmpty) {
      throw StateError('Remote room is not bound yet');
    }
    if (!_mlsGroupReady) {
      throw StateError('MLS group is not ready yet');
    }

    final plaintext = Uint8List.fromList(utf8.encode(json.encode(payload)));
    final encrypted = _asBytes(mls.encryptMessageSync({
      'group_id': _mlsGroupIdJson,
      'plaintext': plaintext,
      'aad': _roomUUID,
    }));
    await client.sendMessage(
      roomId: remoteRoomId,
      clientMsgId: generateUUIDv7(),
      body: <Uint8List>[encrypted],
    );
  }

  Future<void> _sendMediaBytes(
    Uint8List bytes,
    String name,
    String mime,
    String mediaType, {
    ChatMessage? echoMessage,
    Map<String, dynamic>? extraPayload,
  }) async {
    final chunkSize = max(_config.mediaChunkSizeBytes, 64 * 1024);
    final fileId = echoMessage?.id ?? uuidBytesToHex(generateUUIDv7());
    final chunks = (bytes.length / chunkSize).ceil().clamp(1, 9999);

    if (echoMessage != null) {
      _eventController.add(
        SgtpMessageReceived(
          message: echoMessage.copyWith(
              id: fileId, isSending: true, sendProgress: 0),
        ),
      );
    }

    for (var index = 0; index < chunks; index++) {
      final start = index * chunkSize;
      final end = min(start + chunkSize, bytes.length);
      final payload = <String, dynamic>{
        'v': 1,
        'type': mediaType,
        'pub': myUUIDHex,
        'file_id': fileId,
        'name': name,
        'mime': mime,
        'size': bytes.length,
        'data': base64.encode(bytes.sublist(start, end)),
        if (chunks > 1) 'chunk': index,
        if (chunks > 1) 'chunks': chunks,
      };
      _attachSenderAvatar(payload);
      if (index == 0 && extraPayload != null && extraPayload.isNotEmpty) {
        payload.addAll(extraPayload);
      }
      await _sendPayload(payload);
      if (echoMessage != null) {
        _eventController.add(
          SgtpMediaProgress(
            echoId: fileId,
            messageId: fileId,
            progress: (index + 1) / chunks,
          ),
        );
      }
    }

    if (echoMessage != null) {
      _eventController.add(
        SgtpMessageReceived(
          message: echoMessage.copyWith(
            id: fileId,
            isSending: false,
            sendProgress: 1,
          ),
        ),
      );
    }
  }

  Future<void> _handleServerEvent(SgtpServerEvent event) async {
    switch (event) {
      case MlsCommitReceivedNetworkEvent():
        if (!_ownsRemoteRoom(event.roomId)) return;
        await _handleCommit(event.commitBytes);
      case MlsExternalCommitReceivedNetworkEvent():
        if (!_ownsRemoteRoom(event.roomId)) return;
        final joinerHex = _hex(event.joinerPublicKey);
        if (joinerHex.isNotEmpty && joinerHex != myUUIDHex) {
          _peerPublicKeys[joinerHex] = joinerHex;
          _ensurePeer(joinerHex);
        }
        await _handleCommit(event.commitBytes);
      case MlsWelcomeReceivedNetworkEvent():
        if (!_isWelcomeForMe(event.targetUserPublicKey)) return;
        await _handleWelcome(event.welcomeBytes);
        _scheduleRemoteRoomBind();
      case MlsMessageReceivedNetworkEvent():
        if (!_ownsRemoteRoom(event.roomId)) return;
        _log.debug(
          'Received MLS message event room={roomId} message={messageId} bodyParts={bodyParts}',
          parameters: {
            'roomId': event.roomId,
            'messageId': event.messageId,
            'bodyParts': event.body.length,
          },
        );
        await _handleIncomingMessage(event);
    }
  }

  Future<void> _handleCommit(Uint8List commitBytes) async {
    await _handleGroupMessage(commitBytes);
  }

  Future<void> _handleWelcome(Uint8List welcomeBytes) async {
    final mls = _mls;
    if (mls == null) return;
    try {
      mls.joinFromWelcomeSync(welcomeBytes);
      _mlsGroupReady = true;
      _remoteRoomBindRetryTimer?.cancel();
      _remoteRoomBindRetryTimer = null;
      _log.info('Joined MLS group from welcome for room {roomId}',
          parameters: {'roomId': _remoteRoomId ?? roomUUIDHex});
      _emitReadyIfNeeded(force: true);
    } catch (e, st) {
      _log.warning(
        'MLS welcome failed for room {roomId}: {error}',
        parameters: {'roomId': _remoteRoomId ?? roomUUIDHex, 'error': e},
        error: e,
        stackTrace: st,
      );
      _eventController.add(SgtpError(
        error:
            'MLS welcome failed: $e. Ask the other participant to reconnect or recreate the chat.',
      ));
    }
  }

  Future<void> _joinFromStoredWelcome() async {
    if (_mlsGroupReady) return;
    final client = _rpcChat;
    final remoteRoomId = _remoteRoomId;
    if (client == null || remoteRoomId == null || remoteRoomId.isEmpty) return;
    try {
      final welcome = await client.fetchWelcome(roomId: remoteRoomId);
      if (welcome.welcomeBytes.isEmpty) return;
      await _handleWelcome(welcome.welcomeBytes);
    } catch (e, st) {
      _log.warning(
        'fetchWelcome failed for room {roomId}: {error}',
        parameters: {'roomId': remoteRoomId, 'error': e},
        error: e,
        stackTrace: st,
      );
      _eventController.add(
        SgtpError(
          error:
              'MLS welcome is missing for this room. Ask the other participant to reconnect or recreate the chat.',
        ),
      );
    }
  }

  Future<void> _handleIncomingMessage(
      MlsMessageReceivedNetworkEvent event) async {
    final senderHex = _hex(event.senderPublicKey);
    _peerPublicKeys[senderHex] = senderHex;
    _ensurePeer(senderHex);
    for (final item in event.body) {
      final plaintext = await _handleGroupMessage(item);
      _log.debug(
        'MLS message plaintext decoded={decoded} message={messageId}',
        parameters: {
          'decoded': plaintext != null,
          'messageId': event.messageId,
        },
      );
      if (plaintext == null) continue;
      await _emitDecodedPayload(
        payload: plaintext,
        messageId: event.messageId,
        senderUUID: senderHex,
        recvAt: DateTime.now(),
      );
    }
  }

  Future<Uint8List?> _handleGroupMessage(Uint8List payload) async {
    final mls = _mls;
    if (mls == null) return null;
    try {
      final result = mls.handleIncomingSync({
        'kind': 'GroupMessage',
        'payload': payload,
      });
      final events = result is List ? result : <Object?>[result];
      for (final value in events) {
        final event = _map(value);
        final kind = event['kind'] as String?;
        if (kind == 'MessageReceived') {
          return _asBytes(event['message_plaintext']);
        }
        if (kind == 'GroupJoined' ||
            kind == 'GroupStateChanged' ||
            kind == 'MemberAdded') {
          _mlsGroupReady = true;
          _emitReadyIfNeeded(force: true);
        }
      }
    } catch (e) {
      _eventController.add(SgtpError(error: 'MLS incoming failed: $e'));
    }
    return null;
  }

  Future<void> _emitDecodedPayload({
    required Uint8List payload,
    required String messageId,
    required String senderUUID,
    required DateTime recvAt,
  }) async {
    Map<String, dynamic>? decoded;
    try {
      decoded = json.decode(utf8.decode(payload)) as Map<String, dynamic>;
    } catch (_) {}

    if (decoded == null || decoded['v'] != 1) {
      _eventController.add(
        SgtpMessageReceived(
          message: ChatMessage(
            id: messageId,
            senderUUID: senderUUID,
            senderPublicKeyHex: senderUUID.isEmpty ? null : senderUUID,
            content: utf8.decode(payload),
            receivedAt: recvAt,
            isFromHistory: false,
            isFromMe: senderUUID == myUUIDHex,
          ),
        ),
      );
      return;
    }

    final senderPub = (decoded['pub'] as String?) ?? senderUUID;
    if (senderPub.isNotEmpty) {
      _peerPublicKeys[senderPub] = senderPub;
      _ensurePeer(senderPub);
    }
    final effectiveSender = senderPub.isNotEmpty ? senderPub : senderUUID;

    switch (decoded['type'] as String?) {
      case 'text':
        _eventController.add(
          SgtpMessageReceived(
            message: ChatMessage(
              id: messageId,
              senderUUID: effectiveSender,
              senderPublicKeyHex: senderPub,
              content: (decoded['text'] as String?) ?? '',
              receivedAt: recvAt,
              isFromHistory: false,
              isFromMe: effectiveSender == myUUIDHex,
              replyToId: decoded['reply_to_id'] as String?,
              replyToContent: decoded['reply_to_content'] as String?,
              replyToSender: decoded['reply_to_sender'] as String?,
            ),
          ),
        );
      case 'image':
      case 'video':
      case 'voice':
      case 'video_note':
        await _handleMediaPayload(
          messageId: messageId,
          senderUUID: effectiveSender,
          senderPub: senderPub,
          recvAt: recvAt,
          payload: decoded,
          type: decoded['type'] as String,
        );
      case 'message_read':
        final readId = decoded['msg_id'] as String?;
        if (readId != null) {
          _eventController.add(
            SgtpMessageReadReceived(
              readMessageId: readId,
              readerUUID: effectiveSender,
              readerPublicKeyHex: senderPub,
            ),
          );
        }
      case 'reaction':
        final targetId = decoded['msg_id'] as String?;
        final emoji = decoded['emoji'] as String?;
        if (targetId != null && emoji != null) {
          _eventController.add(
            SgtpReactionReceived(
              messageId: targetId,
              emoji: emoji,
              senderUUID: effectiveSender,
              add: (decoded['add'] as bool?) ?? true,
            ),
          );
        }
      case 'chat_meta':
        final name = (decoded['name'] as String?) ?? 'Chat';
        final avatarRaw = decoded['avatar'] as String?;
        final avatarBytes = avatarRaw == null ? null : base64.decode(avatarRaw);
        _eventController.add(
          SgtpChatMetadataReceived(
            chatName: name,
            avatarBytes: avatarBytes,
            senderUUID: effectiveSender,
          ),
        );
    }
  }

  Future<void> _handleMediaPayload({
    required String messageId,
    required String senderUUID,
    required String? senderPub,
    required DateTime recvAt,
    required Map<String, dynamic> payload,
    required String type,
  }) async {
    final chunk = base64.decode((payload['data'] as String?) ?? '');
    final fileId = (payload['file_id'] as String?) ?? messageId;
    final name = (payload['name'] as String?) ?? type;
    final mime = (payload['mime'] as String?) ?? 'application/octet-stream';
    final totalChunks = (payload['chunks'] as num?)?.toInt() ?? 1;
    final chunkIndex = (payload['chunk'] as num?)?.toInt() ?? 0;
    final videoNoteMetadata = type == 'video_note'
        ? VideoNoteMetadata.fromPayloadJson(payload)
        : null;

    if (totalChunks <= 1) {
      _eventController.add(
        SgtpMessageReceived(
          message: _mediaMessage(
            id: fileId,
            senderUUID: senderUUID,
            senderPub: senderPub,
            name: name,
            mime: mime,
            recvAt: recvAt,
            bytes: chunk,
            type: type,
            videoNoteMetadata: videoNoteMetadata,
          ),
        ),
      );
      return;
    }

    final pending = _pendingMedia.putIfAbsent(
      fileId,
      () => _PendingMedia(
        id: fileId,
        type: type,
        name: name,
        mime: mime,
        chunks: totalChunks,
        senderUUID: senderUUID,
        senderPublicKeyHex: senderPub,
        videoNoteMetadata: videoNoteMetadata,
      ),
    );
    pending.put(chunkIndex, chunk);
    if (!pending.isComplete) return;

    _pendingMedia.remove(fileId);
    _eventController.add(
      SgtpMessageReceived(
        message: _mediaMessage(
          id: pending.id,
          senderUUID: pending.senderUUID,
          senderPub: pending.senderPublicKeyHex,
          name: pending.name,
          mime: pending.mime,
          recvAt: recvAt,
          bytes: pending.assemble(),
          type: pending.type,
          videoNoteMetadata: pending.videoNoteMetadata,
        ),
      ),
    );
  }

  ChatMessage _mediaMessage({
    required String id,
    required String senderUUID,
    required String? senderPub,
    required String name,
    required String mime,
    required DateTime recvAt,
    required Uint8List bytes,
    required String type,
    VideoNoteMetadata? videoNoteMetadata,
  }) {
    switch (type) {
      case 'image':
        return ChatMessage(
          id: id,
          senderUUID: senderUUID,
          senderPublicKeyHex: senderPub,
          content: name,
          imageBytes: bytes,
          mediaMime: mime,
          mediaName: name,
          type: MessageType.image,
          receivedAt: recvAt,
          isFromHistory: false,
          isFromMe: senderUUID == myUUIDHex,
        );
      case 'video':
        return ChatMessage(
          id: id,
          senderUUID: senderUUID,
          senderPublicKeyHex: senderPub,
          content: name,
          videoBytes: bytes,
          mediaMime: mime,
          mediaName: name,
          type: MessageType.video,
          receivedAt: recvAt,
          isFromHistory: false,
          isFromMe: senderUUID == myUUIDHex,
        );
      case 'video_note':
        return ChatMessage(
          id: id,
          senderUUID: senderUUID,
          senderPublicKeyHex: senderPub,
          content: name,
          videoBytes: bytes,
          mediaMime: mime,
          mediaName: name,
          type: MessageType.videoNote,
          videoNoteMetadata: videoNoteMetadata,
          receivedAt: recvAt,
          isFromHistory: false,
          isFromMe: senderUUID == myUUIDHex,
        );
      default:
        return ChatMessage(
          id: id,
          senderUUID: senderUUID,
          senderPublicKeyHex: senderPub,
          content: name,
          audioBytes: bytes,
          mediaMime: mime,
          mediaName: name,
          type: MessageType.voice,
          receivedAt: recvAt,
          isFromHistory: false,
          isFromMe: senderUUID == myUUIDHex,
        );
    }
  }

  void _seedKnownPeerPublicKeys() {
    for (final peerHex in _whitelist) {
      if (peerHex == myUUIDHex) continue;
      _peerPublicKeys.putIfAbsent(peerHex, () => peerHex);
      _ensurePeer(peerHex);
    }
  }

  void _ensurePeer(String peerHex) {
    if (peerHex.isEmpty ||
        peerHex == myUUIDHex ||
        _peers.containsKey(peerHex)) {
      return;
    }
    _peers[peerHex] = PeerInfo(
      uuid: peerHex,
      uuidBytes: hexToBytes(peerHex),
      ed25519PubKey: hexToBytes(peerHex),
      sharedKey: Uint8List(32),
      protocolVersion: 2,
      handshakeComplete: true,
    );
    _peerPublicKeys[peerHex] = peerHex;
    _eventController.add(
      SgtpPeerJoined(peerUUID: peerHex, ed25519PubHex: peerHex),
    );
  }

  Future<void> _loadRemoteRoomId() async {
    final repo = _metadataRepository;
    if (repo == null) {
      if (_isDirectRoom) {
        _remoteRoomId = roomUUIDHex;
      }
      return;
    }
    final metadata = await repo.loadChat(
      roomUUIDHex,
      serverAddress: _config.serverAddr,
    );
    _isDirectRoom = metadata?.isDirectMessage ?? _config.isDirectMessage;
    final remote = (metadata?.remoteRoomId ?? '').trim();
    _remoteRoomId = remote.isEmpty
        ? (_isDirectRoom ? roomUUIDHex : null)
        : _normalizeRoomId(remote);
  }

  Future<void> _saveRemoteRoomId(String roomId) async {
    _remoteRoomId = roomId;
    final repo = _metadataRepository;
    if (repo == null) return;
    final existing = await repo.loadChat(
      roomUUIDHex,
      serverAddress: _config.serverAddr,
    );
    final now = DateTime.now();
    final metadata = (existing ??
            ChatMetadata(
              uuid: roomUUIDHex,
              name: _config.chatName,
              serverAddress: _config.serverAddr,
              remoteRoomId: roomId,
              isDirectMessage: _isDirectRoom,
              createdAt: now,
              updatedAt: now,
            ))
        .copyWith(remoteRoomId: roomId, updatedAt: now);
    await repo.saveChat(metadata);
  }

  void _emitReadyIfNeeded({required bool force}) {
    if (_readyEmitted || !force) return;
    _readyEmitted = true;
    _eventController.add(
      SgtpReady(isMaster: _isMaster, roomUUIDHex: roomUUIDHex),
    );
  }

  void _scheduleInviteRetry() {
    _inviteRetryTimer?.cancel();
    if (!_isMaster || _isDirectRoom) return;
    _inviteRetryTimer = Timer.periodic(const Duration(seconds: 5), (_) async {
      if (!_connected) return;
      try {
        await _inviteKnownPeers();
      } catch (e) {
        _log.warning('invite retry failed: {error}', parameters: {'error': e});
      }
    });
  }

  void _scheduleRemoteRoomBind() {
    if (_isMaster ||
        _isDirectRoom ||
        !_connected ||
        (_remoteRoomId ?? '').isNotEmpty ||
        _pendingRemoteRoomBind != null) {
      return;
    }
    _pendingRemoteRoomBind = _bindRemoteRoomAfterWelcome();
  }

  Future<void> _bindRemoteRoomAfterWelcome() async {
    try {
      await Future<void>.delayed(const Duration(milliseconds: 750));
      if (!_connected || (_remoteRoomId ?? '').isNotEmpty) return;
      await _ensureRemoteRoomBound();
      if ((_remoteRoomId ?? '').isNotEmpty && !_mlsGroupReady) {
        await _joinFromStoredWelcome();
      }
    } catch (e, st) {
      _log.warning(
        'deferred remote room bind failed: {error}',
        parameters: {'error': e},
        error: e,
        stackTrace: st,
      );
    } finally {
      _pendingRemoteRoomBind = null;
    }
  }

  void _scheduleRemoteRoomBindRetry() {
    if (_isMaster ||
        _isDirectRoom ||
        !_connected ||
        _mlsGroupReady ||
        (_remoteRoomId ?? '').isNotEmpty ||
        _remoteRoomBindRetryTimer != null) {
      return;
    }
    _log.info(
      'Waiting for remote room invitation for room {roomId}',
      parameters: {'roomId': roomUUIDHex},
    );
    _remoteRoomBindRetryTimer =
        Timer.periodic(const Duration(seconds: 3), (_) async {
      if (!_connected || _mlsGroupReady) {
        _remoteRoomBindRetryTimer?.cancel();
        _remoteRoomBindRetryTimer = null;
        return;
      }
      try {
        await _ensureRemoteRoomBound();
        if ((_remoteRoomId ?? '').isEmpty) {
          return;
        }
        await _joinFromStoredWelcome();
        if (_mlsGroupReady) {
          _remoteRoomBindRetryTimer?.cancel();
          _remoteRoomBindRetryTimer = null;
        }
      } catch (e, st) {
        _log.warning(
          'remote room invitation retry failed: {error}',
          parameters: {'error': e},
          error: e,
          stackTrace: st,
        );
      }
    });
  }

  void _attachSenderAvatar(Map<String, dynamic> payload) {
    final avatar = _userAvatarBytes;
    if (avatar != null && avatar.isNotEmpty) {
      payload['sender_avatar'] = base64.encode(avatar);
    }
  }

  static Set<String> _normalizeWhitelist(Set<String> whitelist) {
    return whitelist
        .map((item) => item.trim().toLowerCase())
        .where((item) => item.isNotEmpty)
        .toSet();
  }

  bool _ownsRemoteRoom(String roomId) =>
      roomId.isNotEmpty && roomId == (_remoteRoomId ?? '');

  bool _isWelcomeForMe(Uint8List targetUserPublicKey) =>
      _hex(targetUserPublicKey) == myUUIDHex;

  Uint8List? get _directPeerPublicKey {
    final peerHex = (_config.directPeerPublicKeyHex ?? '').trim().toLowerCase();
    if (peerHex.length != 64) return null;
    return hexToBytes(peerHex);
  }

  Map<String, dynamic> _map(Object? value) {
    if (value is Map<String, dynamic>) return value;
    if (value is Map) {
      return value.map((key, item) => MapEntry('$key', item));
    }
    return <String, dynamic>{};
  }

  Uint8List _asBytes(Object? value) {
    if (value is Uint8List) return value;
    if (value is List<int>) return Uint8List.fromList(value);
    if (value is List) {
      return Uint8List.fromList(value.map((e) => (e as num).toInt()).toList());
    }
    if (value is String) return base64.decode(value);
    return Uint8List(0);
  }
}

String _hex(Uint8List bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

String _uuidString(Uint8List bytes) {
  final hex = uuidBytesToHex(bytes);
  if (hex.length != 32) return hex;
  return '${hex.substring(0, 8)}-'
      '${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-'
      '${hex.substring(16, 20)}-'
      '${hex.substring(20)}';
}

String _normalizeRoomId(String roomId) =>
    roomId.trim().toLowerCase().replaceAll('-', '');
