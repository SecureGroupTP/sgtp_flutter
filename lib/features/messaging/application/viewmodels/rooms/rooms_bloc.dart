import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:sgtp_flutter/core/app_log.dart';
import 'package:sgtp_flutter/core/network/sgtp_connection_service.dart';
import 'package:sgtp_flutter/core/sgtp_transport.dart';
import 'package:sgtp_flutter/core/uuid_v7.dart';
import 'package:sgtp_flutter/features/messaging/application/models/messaging_models.dart';
import 'package:sgtp_flutter/features/messaging/application/services/media_storage_service.dart';
import 'package:sgtp_flutter/features/messaging/application/services/message_notification_service.dart';
import 'package:sgtp_flutter/features/messaging/application/viewmodels/chat/chat_bloc.dart';
import 'package:sgtp_flutter/features/messaging/application/viewmodels/chat/chat_event.dart';
import 'package:sgtp_flutter/features/messaging/application/viewmodels/chat/chat_state.dart';
import 'package:sgtp_flutter/features/messaging/data/services/server_v2_mls_client.dart';
import 'package:sgtp_flutter/features/messaging/application/viewmodels/rooms/rooms_event.dart';
import 'package:sgtp_flutter/features/messaging/application/viewmodels/rooms/rooms_state.dart';
import 'package:sgtp_flutter/features/messaging/domain/entities/message.dart';
import 'package:sgtp_flutter/features/messaging/domain/entities/sgtp_config.dart';
import 'package:sgtp_flutter/features/messaging/domain/repositories/chat_storage_gateway.dart';
import 'package:sgtp_flutter/features/messaging/domain/repositories/i_sgtp_session.dart';
import 'package:sgtp_flutter/features/settings/application/services/settings_management_service.dart';

// Internal event — triggers a rebuild when any ChatBloc status changes.
class _RoomsRefresh extends RoomsEvent {
  const _RoomsRefresh();
  @override
  List<Object?> get props => [];
}

class RoomsBloc extends Bloc<RoomsEvent, RoomsState> {
  final _log = AppLog('RoomsBloc');
  final String _accountId;
  SgtpConfig _baseConfig;
  final Map<String, String> _nicknames;
  final SettingsManagementService _settings;
  final ChatStorageGateway _chatStorage;
  final SgtpConnectionService _connectionService;
  final MessagingMediaStorageService _mediaStorageService;
  final MessageNotificationService _messageNotificationService;
  final SgtpSessionFactory _sessionFactory;
  Map<String, Uint8List> _contactAvatarsByPub = const {};
  Uint8List? _userAvatar;
  DateTime? _lastServerRoomSyncAt;
  final Map<String, StreamSubscription<dynamic>> _chatSubs = {};
  late final ChatMetadataStore _chatMetadataRepo;

  static const int _maxParallelConnects = 3;
  int _activeConnects = 0;
  final Queue<({String key, ChatBloc bloc, ChatConnect event})> _connectQueue =
      Queue();
  final Set<String> _connectInFlightKeys = {};
  final Map<String, Set<String>> _knownMessageIdsByRoomKey = {};

  RoomsBloc({
    required String accountId,
    required SgtpConfig baseConfig,
    required Map<String, String> nicknames,
    required SettingsManagementService settingsRepository,
    required ChatStorageGateway chatStorage,
    required SgtpConnectionService connectionService,
    required MessagingMediaStorageService mediaStorageService,
    required MessageNotificationService messageNotificationService,
    required String serverAddress,
    required SgtpSessionFactory sessionFactory,
    Uint8List? userAvatar,
  })  : _baseConfig = baseConfig,
        _accountId = accountId,
        _nicknames = nicknames,
        _settings = settingsRepository,
        _chatStorage = chatStorage,
        _connectionService = connectionService,
        _mediaStorageService = mediaStorageService,
        _messageNotificationService = messageNotificationService,
        _sessionFactory = sessionFactory,
        _userAvatar = userAvatar,
        super(RoomsState(serverAddress: serverAddress)) {
    _chatMetadataRepo = chatStorage.metadataForAccount(accountId);
    on<RoomsCreateRoom>(_onCreate);
    on<RoomsJoinRoom>(_onJoin);
    on<RoomsRemoveRoom>(_onRemove);
    on<RoomsUpdateNicknames>(_onUpdateNicknames);
    on<RoomsUpdateContactAvatars>(_onUpdateContactAvatars);
    on<RoomsLoadStoredChats>(_onLoadStoredChats);
    on<RoomsSyncStoredChats>(_onSyncStoredChats);
    on<RoomsDeleteStoredChat>(_onDeleteStoredChat);
    on<RoomsUpsertChat>(_onUpsertChat);
    on<_RoomsRefresh>(_onRefresh);
  }

  /// Update the user avatar in all active room blocs.
  void setUserAvatar(Uint8List? avatar) {
    _userAvatar = avatar;
    for (final room in state.rooms) {
      room.chatBloc.add(ChatSetUserAvatar(avatar));
    }
  }

  // ── Event handlers ────────────────────────────────────────────────────────

  Future<void> _onCreate(
      RoomsCreateRoom event, Emitter<RoomsState> emit) async {
    final roomUUID = generateUUIDv7();
    final configOverride = await _configOverrideForTarget(
      serverAddress: event.serverAddress,
      transport: event.transport,
      useTls: event.useTls,
    );
    _addRoom(
      roomUUID,
      emit,
      configOverride: configOverride,
      highPriorityConnect: true,
    );
  }

  Future<void> _onJoin(RoomsJoinRoom event, Emitter<RoomsState> emit) async {
    final hexClean = event.uuidHex.trim().replaceAll('-', '');
    if (hexClean.length != 32) {
      emit(state.copyWith(error: 'UUID must be 32 hex chars (without dashes)'));
      return;
    }
    try {
      final bytes = hexToBytes(hexClean);
      final configOverride = await _configOverrideForTarget(
        serverAddress: event.serverAddress,
        transport: event.transport,
        useTls: event.useTls,
      );
      _addRoom(
        bytes,
        emit,
        configOverride: configOverride,
        isDirectMessage: event.isDirectMessage,
        bootstrapDirectRoom: event.bootstrapDirectRoom,
        directPeerPublicKeyHex: event.directPeerPublicKeyHex,
        highPriorityConnect: true,
      );
    } catch (_) {
      emit(state.copyWith(error: 'Invalid UUID format'));
    }
  }

  Future<SgtpConfig?> _configOverrideForTarget({
    String? serverAddress,
    SgtpTransportFamily? transport,
    bool? useTls,
  }) async {
    final addr = serverAddress?.trim();
    int? discoveryPort;
    if ((transport == null || useTls == null) &&
        addr != null &&
        addr.isNotEmpty) {
      final resolved = await _resolveServerTransport(addr);
      transport ??= resolved?.$1;
      useTls ??= resolved?.$2;
      discoveryPort ??= resolved?.$3;
    }

    if ((addr == null || addr.isEmpty) && transport == null && useTls == null) {
      return null;
    }

    var cfg = _baseConfig;
    if (addr != null && addr.isNotEmpty) {
      cfg = cfg.copyWith(serverAddr: addr);
    }
    if (discoveryPort != null) {
      cfg = cfg.copyWith(discoveryPort: discoveryPort);
    }
    if (transport != null) {
      cfg = cfg.copyWith(transport: transport);
    }
    if (useTls != null) {
      cfg = cfg.copyWith(useTls: useTls);
    }
    return cfg;
  }

  Future<(SgtpTransportFamily, bool, int?)?> _resolveServerTransport(
      String serverAddress) async {
    final target = _normalizeAddress(serverAddress);
    if (target.isEmpty) return null;
    final nodes = await _settings.loadNodes();
    for (final node in nodes) {
      if (_normalizeAddress(node.chatAddress) == target ||
          _normalizeAddress(node.discoveryAddress) == target) {
        return (node.transport, node.useTls, node.effectiveDiscoveryPort);
      }
    }
    return null;
  }

  String _normalizeAddress(String raw) {
    return raw
        .trim()
        .replaceAll(RegExp(r'^https?://', caseSensitive: false), '')
        .replaceAll(RegExp(r'^wss?://', caseSensitive: false), '')
        .toLowerCase();
  }

  String _roomKey(String roomUUID, String serverAddress) =>
      '${roomUUID.trim().toLowerCase()}@${_normalizeAddress(serverAddress)}';


  void _onUpdateNicknames(
      RoomsUpdateNicknames event, Emitter<RoomsState> emit) {
    // Store locally so new rooms created later get the latest nicknames.
    _nicknames
      ..clear()
      ..addAll(event.nicknames);
    // Hot-push to all already-running rooms so nick appears immediately.
    for (final room in state.rooms) {
      room.chatBloc.add(ChatUpdateNicknames(event.nicknames));
    }
  }

  void _onUpdateContactAvatars(
      RoomsUpdateContactAvatars event, Emitter<RoomsState> emit) {
    _contactAvatarsByPub = Map<String, Uint8List>.from(event.avatarsByPubkey);
    for (final room in state.rooms) {
      room.chatBloc.add(ChatUpdateContactAvatars(event.avatarsByPubkey));
    }
  }

  // ── Stored chats ────────────────────────────────────────────────────────

  Future<void> _onLoadStoredChats(
      RoomsLoadStoredChats event, Emitter<RoomsState> emit) async {
    await _syncServerRoomsIntoMetadata();
    final allMetadata = await _chatMetadataRepo.loadAllChats();
    final targetServer = _normalizeAddress(state.serverAddress);
    final filtered = allMetadata
        .where((m) => _normalizeAddress(m.serverAddress) == targetServer)
        .toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

    // Chats should be online by default. Re-hydrate active rooms from stored
    // chat metadata on startup / server switch.
    if (targetServer.isNotEmpty && filtered.isNotEmpty) {
      final configOverride =
          await _configOverrideForTarget(serverAddress: state.serverAddress);
      for (final chat in filtered) {
        try {
          _addRoom(
            hexToBytes(chat.uuid),
            emit,
            configOverride: configOverride,
            isDirectMessage: chat.isDirectMessage,
          );
        } catch (_) {}
      }
    }

    emit(state.copyWith(storedChats: filtered));
  }

  Future<void> _onSyncStoredChats(
      RoomsSyncStoredChats event, Emitter<RoomsState> emit) async {
    var changed = false;
    for (final room in state.rooms) {
      final chatState = room.chatBloc.state;
      final existing = await _chatMetadataRepo.loadChat(
        room.roomUUID,
        serverAddress: room.serverAddress,
      );
      final nextName = chatState.chatName.trim();
      final shouldSaveName = nextName.isNotEmpty && nextName != 'Chat';
      final hasAvatar = chatState.chatAvatarBytes != null &&
          chatState.chatAvatarBytes!.isNotEmpty;

      final needsSave = existing == null ||
          (shouldSaveName && existing.name != nextName) ||
          (hasAvatar &&
              (existing.avatarBytes == null ||
                  existing.avatarBytes!.length !=
                      chatState.chatAvatarBytes!.length));

      if (!needsSave) continue;

      final now = DateTime.now();
      await _chatMetadataRepo.saveChat(ChatMetadata(
        uuid: room.roomUUID,
        serverAddress: room.serverAddress,
        remoteRoomId: existing?.remoteRoomId,
        name:
            shouldSaveName ? nextName : (existing?.name ?? chatState.chatName),
        avatarBytes:
            hasAvatar ? chatState.chatAvatarBytes : existing?.avatarBytes,
        isDirectMessage: existing?.isDirectMessage ?? chatState.isDirectChat,
        createdAt: existing?.createdAt ?? now,
        updatedAt: existing?.updatedAt ?? now,
        windowWidth: existing?.windowWidth,
        windowHeight: existing?.windowHeight,
      ));
      changed = true;
    }

    if (changed) {
      add(const RoomsLoadStoredChats());
    }
  }

  Future<void> _onDeleteStoredChat(
      RoomsDeleteStoredChat event, Emitter<RoomsState> emit) async {
    await _chatStorage
        .historyForChat(
          accountId: _accountId,
          serverAddress: event.serverAddress,
          chatUUID: event.uuid,
        )
        .clear();
    await _chatMetadataRepo.deleteChat(
      event.uuid,
      serverAddress: event.serverAddress,
    );
    add(const RoomsLoadStoredChats());
  }

  Future<void> _onUpsertChat(
      RoomsUpsertChat event, Emitter<RoomsState> emit) async {
    final server = (event.serverAddress ?? '').trim();
    if (server.isEmpty) return;
    final existing =
        await _chatMetadataRepo.loadChat(event.uuid, serverAddress: server);
    final now = DateTime.now();
    await _chatMetadataRepo.saveChat(ChatMetadata(
      uuid: event.uuid,
      name: (event.name != null && event.name!.isNotEmpty)
          ? event.name!
          : (existing?.name ?? 'Chat'),
      serverAddress: server,
      remoteRoomId: existing?.remoteRoomId,
      avatarBytes: event.avatarBytes ?? existing?.avatarBytes,
      isDirectMessage: existing?.isDirectMessage ?? false,
      createdAt: existing?.createdAt ?? now,
      updatedAt: now,
      windowWidth: existing?.windowWidth,
      windowHeight: existing?.windowHeight,
    ));
    add(const RoomsLoadStoredChats());
  }

  Future<bool> _syncServerRoomsIntoMetadata() async {
    final targetServer = state.serverAddress.trim();
    if (targetServer.isEmpty) return false;

    final lastSync = _lastServerRoomSyncAt;
    final now = DateTime.now();
    if (lastSync != null && now.difference(lastSync).inSeconds < 15) {
      return true;
    }

    final config = _baseConfig
        .copyWith(accountId: _accountId)
        .copyWith(serverAddr: targetServer);
    final client = ServerV2MlsClient(
      rpcProvider: () => _connectionService.acquireRpc(config),
      sharedServerEvents: _connectionService.serverEvents,
    );
    var synced = 0;
    try {
      String? cursor;
      do {
        final page = await client.listChatRooms(limit: 100, cursor: cursor);
        for (final item in page.items) {
          final room = await client.getChatRoom(item.roomId);
          final localRoomUUID = _localRoomUUIDFromDescription(
            room.room.description,
          );
          if (localRoomUUID == null) continue;

          final existing = await _chatMetadataRepo.loadChat(
            localRoomUUID,
            serverAddress: targetServer,
          );
          final updatedAt = item.updatedAtUs > 0
              ? DateTime.fromMicrosecondsSinceEpoch(
                  item.updatedAtUs,
                  isUtc: true,
                ).toLocal()
              : now;
          final serverName = room.room.title.trim();
          final existingName = (existing?.name ?? '').trim();
          final isDirect = existing?.isDirectMessage ?? false;
          final serverNameLower = serverName.toLowerCase();
          final isAutoPeerTitle =
              RegExp(r'^peer[_\s][0-9a-f]{8}$').hasMatch(serverNameLower);
          final inferredDirect = isDirect || isAutoPeerTitle;
          final sanitizedServerName = isAutoPeerTitle ? '' : serverName;
          final existingNameLower = existingName.toLowerCase();
          final isAutoPeerExisting =
              RegExp(r'^peer[_\s][0-9a-f]{8}$').hasMatch(existingNameLower);
          final sanitizedExistingName = existingName.isNotEmpty &&
                  existingName != 'Chat' &&
                  !(inferredDirect && isAutoPeerExisting)
              ? existingName
              : '';
          final effectiveName = sanitizedExistingName.isNotEmpty
              ? sanitizedExistingName
              : (sanitizedServerName.isNotEmpty
                  ? sanitizedServerName
                  : (inferredDirect ? 'Direct chat' : 'Chat'));
          await _chatMetadataRepo.saveChat(ChatMetadata(
            uuid: localRoomUUID,
            name: effectiveName,
            serverAddress: targetServer,
            remoteRoomId: room.room.roomId,
            avatarBytes: existing?.avatarBytes,
            isDirectMessage: inferredDirect,
            createdAt: existing?.createdAt ?? updatedAt,
            updatedAt: updatedAt.isAfter(existing?.updatedAt ?? DateTime(0))
                ? updatedAt
                : (existing?.updatedAt ?? updatedAt),
            windowWidth: existing?.windowWidth,
            windowHeight: existing?.windowHeight,
          ));
          synced++;
        }
        cursor = page.nextCursor;
      } while (cursor != null && cursor.isNotEmpty);
      if (synced > 0) {
        _log.info('Synced {count} server rooms into local metadata',
            parameters: {'count': synced});
      }
      _lastServerRoomSyncAt = DateTime.now();
      return true;
    } catch (e, st) {
      _log.warning(
        'Server room sync failed; keeping local cached rooms: {error}',
        parameters: {'error': e},
        error: e,
        stackTrace: st,
      );
      return false;
    } finally {
      await client.close();
    }
  }

  String? _localRoomUUIDFromDescription(String? description) {
    final raw = (description ?? '').trim().toLowerCase();
    if (!raw.startsWith('sgtp:')) return null;
    final clean = raw.substring(5).replaceAll('-', '');
    if (clean.length != 32 || !RegExp(r'^[0-9a-f]{32}$').hasMatch(clean)) {
      return null;
    }
    return clean;
  }

  // ── Room management ─────────────────────────────────────────────────────

  void _addRoom(Uint8List roomUUID, Emitter<RoomsState> emit,
      {SgtpConfig? configOverride,
      bool isDirectMessage = false,
      bool bootstrapDirectRoom = false,
      String? directPeerPublicKeyHex,
      bool highPriorityConnect = false}) {
    final hexUUID = uuidBytesToHex(roomUUID);
    final config = (configOverride ?? _baseConfig)
        .copyWith(accountId: _accountId)
        .copyWithRoomUUID(roomUUID)
        .copyWithDirectRoom(
          isDirectMessage: isDirectMessage,
          bootstrapDirectRoom: bootstrapDirectRoom,
          directPeerPublicKeyHex: directPeerPublicKeyHex,
        );
    final targetServer = _normalizeAddress(config.serverAddr);
    final alreadyJoined = state.rooms.any(
      (r) =>
          r.roomUUID == hexUUID &&
          _normalizeAddress(r.serverAddress) == targetServer,
    );
    if (alreadyJoined) {
      // Idempotent join: repeated taps / duplicate intents for the same
      // room+server should not surface an error in UI.
      return;
    }
    final chatBloc = ChatBloc(
      accountId: _accountId,
      storageGateway: _chatStorage,
      mediaStorageService: _mediaStorageService,
      sessionFactory: _sessionFactory,
    );

    // Push user avatar into the new bloc
    if (_userAvatar != null) {
      chatBloc.add(ChatSetUserAvatar(_userAvatar));
    }
    if (_contactAvatarsByPub.isNotEmpty) {
      chatBloc.add(ChatUpdateContactAvatars(_contactAvatarsByPub));
    }

    final key = _roomKey(hexUUID, config.serverAddr);
    _knownMessageIdsByRoomKey[key] =
        chatBloc.state.messages.map((m) => m.id).toSet();
    _chatSubs[key] = chatBloc.stream.listen((chatState) {
      // Release a connect slot once the room leaves connecting/handshaking.
      if (_connectInFlightKeys.contains(key) &&
          chatState.status != ChatStatus.connecting &&
          chatState.status != ChatStatus.handshaking) {
        _connectInFlightKeys.remove(key);
        _activeConnects = (_activeConnects - 1).clamp(0, 1 << 30);
        _drainConnectQueue();
      }
      _dispatchNotificationsForRoom(key, chatState);
      add(const _RoomsRefresh());
    });

    final entry = RoomEntry(
      roomUUID: hexUUID,
      serverAddress: config.serverAddr,
      chatBloc: chatBloc,
    );
    emit(state.copyWith(
      rooms: [...state.rooms, entry],
      clearError: true,
    ));

    final connectEvent = ChatConnect(config, nicknames: _nicknames);
    if (highPriorityConnect) {
      _connectQueue.addFirst((key: key, bloc: chatBloc, event: connectEvent));
    } else {
      _connectQueue.addLast((key: key, bloc: chatBloc, event: connectEvent));
    }
    _drainConnectQueue();
  }

  void _drainConnectQueue() {
    while (_activeConnects < _maxParallelConnects && _connectQueue.isNotEmpty) {
      final next = _connectQueue.removeFirst();
      if (next.bloc.isClosed) continue;
      if (_connectInFlightKeys.contains(next.key)) continue;
      _connectInFlightKeys.add(next.key);
      _activeConnects++;
      next.bloc.add(next.event);
    }
  }

  Future<void> _onRemove(
      RoomsRemoveRoom event, Emitter<RoomsState> emit) async {
    final roomKey = _roomKey(event.roomUUID, event.serverAddress);
    await _chatSubs[roomKey]?.cancel();
    _chatSubs.remove(roomKey);
    _knownMessageIdsByRoomKey.remove(roomKey);
    final room = state.rooms
        .where((r) =>
            r.roomUUID == event.roomUUID &&
            _normalizeAddress(r.serverAddress) ==
                _normalizeAddress(event.serverAddress))
        .firstOrNull;
    if (room != null) {
      room.chatBloc.add(const ChatDisconnect());
      await room.chatBloc.close();
    }
    emit(state.copyWith(
      rooms: state.rooms
          .where((r) => !(r.roomUUID == event.roomUUID &&
              _normalizeAddress(r.serverAddress) ==
                  _normalizeAddress(event.serverAddress)))
          .toList(),
      clearError: true,
    ));
  }

  void _onRefresh(_RoomsRefresh event, Emitter<RoomsState> emit) {
    emit(state.copyWith());
  }

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  void _dispatchNotificationsForRoom(String roomKey, ChatState chatState) {
    final knownIds = _knownMessageIdsByRoomKey.putIfAbsent(roomKey, () => {});
    final newMessages = <ChatMessage>[];
    for (final message in chatState.messages) {
      if (knownIds.add(message.id)) {
        newMessages.add(message);
      }
    }
    if (newMessages.isEmpty) return;

    for (final msg in newMessages) {
      final shouldNotify = !msg.isFromMe &&
          !msg.isFromHistory &&
          msg.type != MessageType.system &&
          msg.type != MessageType.messageRead &&
          msg.type != MessageType.reaction &&
          msg.type != MessageType.viewed;
      if (!shouldNotify) continue;

      final senderLabel = chatState.peerNicknames[msg.senderUUID] ??
          chatState.peerNicknamesHistory[msg.senderUUID] ??
          (msg.senderUUID.length >= 8
              ? msg.senderUUID.substring(0, 8)
              : msg.senderUUID);
      final body =
          msg.type == MessageType.text ? msg.content : '[${msg.type.name}]';
      final avatar =
          chatState.peerAvatars[msg.senderUUID] ?? msg.senderAvatarBytes;
      unawaited(
        _messageNotificationService.showMessage(
          sender: senderLabel,
          body: body,
          messageId: msg.id,
          roomId: chatState.roomUUID,
          avatarBytes: avatar,
        ),
      );
    }
  }

  @override
  Future<void> close() async {
    for (final sub in _chatSubs.values) {
      await sub.cancel();
    }
    for (final room in state.rooms) {
      await room.chatBloc.close();
    }
    return super.close();
  }
}
