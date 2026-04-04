import 'dart:async';
import 'dart:convert' show base64, json, utf8, ascii;
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cross_file/cross_file.dart';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:path_provider/path_provider.dart';

import '../core/app_logger.dart';
import '../core/constants.dart';
import '../core/uint64_utils.dart';
import '../core/sgtp_server_options.dart';
import '../core/sgtp_transport.dart';
import '../core/crypto/chacha20_utils.dart';
import '../core/crypto/ed25519_utils.dart';
import '../core/crypto/x25519_utils.dart';
import '../core/protocol/frame_builder.dart';
import '../core/protocol/frame_parser.dart';
import '../core/protocol/packet_types.dart';
import '../core/uuid_v7.dart';
import 'repositories/chat_history_repository.dart';
import 'repositories/settings_repository.dart';
import 'transport/http_sgtp_transport.dart';
import 'transport/server_discovery.dart';
import 'transport/sgtp_transport.dart';
import 'transport/tcp_sgtp_transport.dart';
import 'transport/websocket_sgtp_transport.dart';
import '../domain/entities/message.dart';
import '../domain/entities/peer.dart';
import '../domain/entities/video_note_metadata.dart';

// ---------------------------------------------------------------------------
// Internal types
// ---------------------------------------------------------------------------

class _HistoryRecord {
  final Uint8List senderUUID;
  final Uint8List messageUUID;
  final int timestamp;
  final int nonce;
  final Uint8List plaintext;
  const _HistoryRecord({
    required this.senderUUID,
    required this.messageUUID,
    required this.timestamp,
    required this.nonce,
    required this.plaintext,
  });
}

class _PendingFile {
  final String fileId;
  final String name;
  final String mime;
  final int totalSize;
  final int totalChunks;
  final String senderUUID;
  final String mediaType;
  final VideoNoteMetadata? videoNoteMetadata;

  // Disk-based storage: chunks are written to tempPath as they arrive.
  // Only one copy of the data ever exists — on disk, never fully in RAM.
  final String? tempPath;
  final RandomAccessFile? _raf;
  int _firstChunkSize = 0; // inferred from chunk index 0

  // Memory-based fallback (web or small non-cacheable files).
  final List<Uint8List?>? _memChunks;

  int _receivedCount = 0;

  _PendingFile._({
    required this.fileId,
    required this.name,
    required this.mime,
    required this.totalSize,
    required this.totalChunks,
    required this.senderUUID,
    required this.mediaType,
    this.videoNoteMetadata,
    RandomAccessFile? raf,
    this.tempPath,
    List<Uint8List?>? memChunks,
  })  : _raf = raf,
        _memChunks = memChunks;

  /// Opens a temp file on disk and returns a disk-backed [_PendingFile].
  /// Falls back to in-memory on web.
  static Future<_PendingFile> create({
    required String fileId,
    required String name,
    required String mime,
    required int totalSize,
    required int totalChunks,
    required String senderUUID,
    required String mediaType,
    VideoNoteMetadata? videoNoteMetadata,
    required bool useDisk,
    required String tempPath,
  }) async {
    if (useDisk && !kIsWeb) {
      final f = File(tempPath);
      final raf = await f.open(mode: FileMode.write);
      return _PendingFile._(
        fileId: fileId,
        name: name,
        mime: mime,
        totalSize: totalSize,
        totalChunks: totalChunks,
        senderUUID: senderUUID,
        mediaType: mediaType,
        videoNoteMetadata: videoNoteMetadata,
        raf: raf,
        tempPath: tempPath,
      );
    }
    return _PendingFile._(
      fileId: fileId,
      name: name,
      mime: mime,
      totalSize: totalSize,
      totalChunks: totalChunks,
      senderUUID: senderUUID,
      mediaType: mediaType,
      videoNoteMetadata: videoNoteMetadata,
      memChunks: List.filled(totalChunks, null),
    );
  }

  Future<void> writeChunk(int ci, Uint8List data) async {
    final raf = _raf;
    if (raf != null) {
      if (ci == 0) _firstChunkSize = data.length;
      // Seek to the correct offset using the chunk size learned from chunk 0.
      // On TCP/WS transports chunks arrive in order, so chunk 0 always precedes
      // later chunks and _firstChunkSize is set before it is needed.
      final offset = _firstChunkSize > 0 ? ci * _firstChunkSize : 0;
      await raf.setPosition(offset);
      await raf.writeFrom(data);
    } else {
      final mem = _memChunks;
      if (mem != null && ci < mem.length) mem[ci] = data;
    }
    _receivedCount++;
  }

  bool get isComplete => _receivedCount >= totalChunks;

  /// Assemble in-memory chunks into a single buffer (memory-based path only).
  Uint8List? assembleMemory() {
    final mem = _memChunks;
    if (mem == null) return null;
    final buf = BytesBuilder();
    for (final c in mem) {
      if (c == null) return null;
      buf.add(c);
    }
    return buf.takeBytes();
  }

  Future<void> close() async {
    try {
      await _raf?.flush();
      await _raf?.close();
    } catch (_) {}
  }
}

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

class SgtpConfig {
  final String? accountId;
  final String serverAddr;
  final Uint8List roomUUID;
  final SimpleKeyPairData identityKeyPair;
  final Uint8List myPublicKey;
  final Set<String> whitelist;
  final SgtpTransportFamily transport;
  final bool useTls;
  final String? nodeId;

  /// Initial chat name to send in CHAT_REQUEST and display until updated
  final String chatName;

  /// Initial avatar bytes (PNG/JPEG, ≤ 4 KB)
  final Uint8List? chatAvatarBytes;

  /// How often (seconds) to send pings and prune stale peers. Default 30.
  final int pingIntervalSeconds;

  /// Chunk size for outgoing media payloads.
  final int mediaChunkSizeBytes;

  const SgtpConfig({
    this.accountId,
    required this.serverAddr,
    required this.roomUUID,
    required this.identityKeyPair,
    required this.myPublicKey,
    required this.whitelist,
    this.transport = SgtpTransportFamily.tcp,
    this.useTls = false,
    this.nodeId,
    this.chatName = 'Chat',
    this.chatAvatarBytes,
    this.pingIntervalSeconds = 30,
    this.mediaChunkSizeBytes = SgtpConstants.defaultMediaChunkSize,
  });

  SgtpConfig copyWithRoomUUID(Uint8List roomUUID) => SgtpConfig(
        accountId: accountId,
        serverAddr: serverAddr,
        roomUUID: roomUUID,
        identityKeyPair: identityKeyPair,
        myPublicKey: myPublicKey,
        whitelist: whitelist,
        transport: transport,
        useTls: useTls,
        nodeId: nodeId,
        chatName: chatName,
        chatAvatarBytes: chatAvatarBytes,
        pingIntervalSeconds: pingIntervalSeconds,
        mediaChunkSizeBytes: mediaChunkSizeBytes,
      );

  SgtpConfig copyWithMeta({String? name, Uint8List? avatar}) => SgtpConfig(
        accountId: accountId,
        serverAddr: serverAddr,
        roomUUID: roomUUID,
        identityKeyPair: identityKeyPair,
        myPublicKey: myPublicKey,
        whitelist: whitelist,
        transport: transport,
        useTls: useTls,
        nodeId: nodeId,
        chatName: name ?? chatName,
        chatAvatarBytes: avatar ?? chatAvatarBytes,
        pingIntervalSeconds: pingIntervalSeconds,
        mediaChunkSizeBytes: mediaChunkSizeBytes,
      );

  SgtpConfig copyWith(
          {Set<String>? whitelist,
          String? serverAddr,
          String? accountId,
          int? mediaChunkSizeBytes,
          SgtpTransportFamily? transport,
          bool? useTls,
          String? nodeId}) =>
      SgtpConfig(
        accountId: accountId ?? this.accountId,
        serverAddr: serverAddr ?? this.serverAddr,
        roomUUID: roomUUID,
        identityKeyPair: identityKeyPair,
        myPublicKey: myPublicKey,
        whitelist: whitelist ?? this.whitelist,
        transport: transport ?? this.transport,
        useTls: useTls ?? this.useTls,
        nodeId: nodeId ?? this.nodeId,
        chatName: chatName,
        chatAvatarBytes: chatAvatarBytes,
        pingIntervalSeconds: pingIntervalSeconds,
        mediaChunkSizeBytes: mediaChunkSizeBytes ?? this.mediaChunkSizeBytes,
      );
}

// ---------------------------------------------------------------------------
// Events
// ---------------------------------------------------------------------------

sealed class SgtpEvent {}

class SgtpConnecting extends SgtpEvent {}

class SgtpHandshaking extends SgtpEvent {}

class SgtpReady extends SgtpEvent {
  final bool isMaster;
  final String roomUUIDHex;
  SgtpReady({required this.isMaster, required this.roomUUIDHex});
}

class SgtpMessageReceived extends SgtpEvent {
  final ChatMessage message;
  SgtpMessageReceived({required this.message});
}

class SgtpPeerJoined extends SgtpEvent {
  final String peerUUID;
  final String ed25519PubHex;
  SgtpPeerJoined({required this.peerUUID, required this.ed25519PubHex});
}

class SgtpPeerLeft extends SgtpEvent {
  final String peerUUID;
  SgtpPeerLeft({required this.peerUUID});
}

class SgtpError extends SgtpEvent {
  final String error;
  SgtpError({required this.error});
}

class SgtpDisconnected extends SgtpEvent {}

/// A participant shared their chat metadata (name/avatar).
/// Fired both when receiving a CHAT_REQUEST and when receiving a chat_meta message.
class SgtpChatMetadataReceived extends SgtpEvent {
  final String chatName;
  final Uint8List? avatarBytes;
  final String senderUUID;
  SgtpChatMetadataReceived({
    required this.chatName,
    this.avatarBytes,
    required this.senderUUID,
  });
}

/// A peer sent a read receipt for a specific message.
class SgtpMessageReadReceived extends SgtpEvent {
  final String readMessageId;
  final String readerUUID;
  final String? readerPublicKeyHex;
  SgtpMessageReadReceived({
    required this.readMessageId,
    required this.readerUUID,
    this.readerPublicKeyHex,
  });
}

/// Upload progress for our own outgoing media.
class SgtpMediaProgress extends SgtpEvent {
  final String echoId; // ChatMessage.id of the pending outgoing message
  final String messageId;
  final double progress; // 0.0–1.0
  SgtpMediaProgress(
      {required this.echoId, required this.messageId, required this.progress});
}

/// A peer added or removed an emoji reaction on a message.
class SgtpReactionReceived extends SgtpEvent {
  final String messageId;
  final String emoji;
  final String senderUUID;
  final bool add; // true = add, false = remove
  SgtpReactionReceived({
    required this.messageId,
    required this.emoji,
    required this.senderUUID,
    required this.add,
  });
}

class PersistedHistoryBatchResult {
  final int loaded;
  final int total;

  const PersistedHistoryBatchResult({
    required this.loaded,
    required this.total,
  });
}

// ---------------------------------------------------------------------------
// Client state
// ---------------------------------------------------------------------------

enum _ClientState { disconnected, connecting, waitingHandshake, ready }

// ---------------------------------------------------------------------------
// SgtpClient
// ---------------------------------------------------------------------------

class SgtpClient {
  final SgtpConfig _config;
  final Uint8List _myUUID;
  late final Uint8List _roomUUID;
  final Random _secureRandom = Random.secure();

  final _eventController = StreamController<SgtpEvent>.broadcast();
  Stream<SgtpEvent> get events => _eventController.stream;

  SgtpTransport? _transport;
  final List<int> _receiveBuffer = [];
  _ClientState _state = _ClientState.disconnected;

  final Map<String, PeerInfo> _peers = {};
  SimpleKeyPair? _ephemeralX25519;
  Uint8List? _ephemeralX25519Pub;

  Uint8List? _chatKey;
  int _chatEpoch = 0;
  int _myNonce = 0;

  // Current local chat metadata (can be updated and broadcast)
  String _currentChatName;
  Uint8List? _currentChatAvatar;

  // Keyed by fileId. Values are Futures so concurrent chunk arrivals
  // (frames are processed fire-and-forget) share the same init future.
  final Map<String, Future<_PendingFile>> _pendingFiles = {};

  /// Serial send queue — ensures only one frame is written to the socket at a time.
  /// Without this, concurrent async calls can interleave bytes in the TCP stream,
  /// corrupting the length-prefix framing and causing "payload_length exceeds maximum".
  Future<void> _sendChain = Future.value();

  /// Maps sessionUUID → ed25519PubHex for all ever-seen peers (survives leave).
  final Map<String, String> _peerPublicKeys = {};

  bool _isMaster = false;
  Timer? _ckRotationTimer;
  Timer?
      _keepaliveTimer; // actively pings all known peers to keep connections alive
  Timer? _handshakeRetryTimer; // retries handshake progression while waiting
  bool _infoTimerStarted = false;
  // Serial frame-processing chain: each frame waits for the previous one to
  // finish before starting. This prevents hundreds of concurrent _dispatch
  // calls each holding a decoded media chunk in memory simultaneously.
  Future<void> _frameChain = Future.value();
  final Set<String> _pendingHandshakes = {};
  final Map<String, Timer> _pendingHandshakeTimers = {};
  bool _chatRequestSent = false;
  bool _readyEmitted = false;

  // Mutable copy of the whitelist — updated via updateWhitelist() without reconnect.
  late Set<String> _whitelist;

  final Map<String, int> _peerLastSeen = {};
  Timer? _stalePruneTimer;

  /// Peers already announced via SgtpPeerJoined this session.
  /// Prevents duplicate "joined" messages from keepalive pings / prune races.
  final Set<String> _announcedJoins = {};

  ChatHistoryRepository? _historyRepository;
  bool _historyRequested = false;
  final Map<String, int> _hsiReplies = {};
  Timer? _hsiTimer;

  static const int _histNonceBit = 1 << 62;

  /// Timestamp of the last received bytes from the server.
  /// Used to detect stale TCP connections after returning from background.
  DateTime _lastReceiveAt = DateTime.now();

  SgtpClient(SgtpConfig config)
      : _config = config,
        _myUUID = generateUUIDv7(),
        _currentChatName = config.chatName,
        _currentChatAvatar = config.chatAvatarBytes {
    _roomUUID = config.roomUUID.every((b) => b == 0)
        ? generateUUIDv7()
        : Uint8List.fromList(config.roomUUID);
    _whitelist = Set.unmodifiable(config.whitelist);
    _historyRepository = _buildHistoryRepository();
  }

  bool get isMaster => _isMaster;
  String get myUUIDHex => uuidBytesToHex(_myUUID);
  String get roomUUIDHex => uuidBytesToHex(_roomUUID);
  List<String> get peerUUIDs => _peers.keys.toList();

  /// Returns sessionUUID → ed25519PubHex for all ever-seen peers.
  Map<String, String> get peerPublicKeys => Map.unmodifiable(_peerPublicKeys);

  /// When the socket last received any data. Used to detect dead TCP connections.
  DateTime get lastReceiveAt => _lastReceiveAt;

  ChatHistoryRepository? _buildHistoryRepository() {
    final accountId = (_config.accountId ?? _config.nodeId ?? '').trim();
    final chatUUID = roomUUIDHex.trim();
    if (accountId.isEmpty || chatUUID.isEmpty) return null;
    return ChatHistoryRepository(
      accountId: accountId,
      serverAddress: _config.serverAddr,
      chatUUID: chatUUID,
    );
  }

  Future<int> persistedHistoryCount() async {
    final repo = _historyRepository;
    if (repo == null) return 0;
    return repo.count();
  }

  Future<PersistedHistoryBatchResult> replayPersistedHistoryBatch({
    required int offsetFromEnd,
    int limit = 100,
  }) async {
    final repo = _historyRepository;
    if (repo == null) {
      return const PersistedHistoryBatchResult(loaded: 0, total: 0);
    }
    final total = await repo.count();
    final records = await repo.readBatchFromEnd(
      offsetFromEnd: offsetFromEnd,
      limit: limit,
    );
    for (final record in records) {
      await _emitRecordFromHistory(record);
    }
    return PersistedHistoryBatchResult(loaded: records.length, total: total);
  }

  /// User avatar is local UI-only and is not exchanged in SGTP MESSAGE payloads.
  void setUserAvatar(Uint8List? avatar) {}

  /// Hot-update the peer whitelist without reconnecting.
  /// Newly added keys are accepted on the next ping/pong; removed keys are
  /// dropped at the next prune cycle.
  void updateWhitelist(Set<String> whitelist) {
    _whitelist = Set.unmodifiable(whitelist);
  }

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  Future<void> connect() async {
    if (_state != _ClientState.disconnected) return;
    _state = _ClientState.connecting;
    _eventController.add(SgtpConnecting());
    AppLogger.i('Connecting to server...', tag: 'SGTP');
    try {
      _ephemeralX25519 = await generateEphemeralKeyPair();
      _ephemeralX25519Pub = await extractPublicKeyBytes(_ephemeralX25519!);
      final (host, _) = _parseHostPortOrThrow(_config.serverAddr);

      SgtpServerOptions? options;
      try {
        final result = await SgtpServerDiscovery.discover(host);
        options = result.opts;
        final nodeId = (_config.nodeId ?? '').trim();
        if (nodeId.isNotEmpty) {
          await SettingsRepository().saveNodeServerOptions(nodeId, options);
        }
      } catch (e) {
        final nodeId = (_config.nodeId ?? '').trim();
        if (nodeId.isNotEmpty) {
          options = await SettingsRepository().loadNodeServerOptions(nodeId);
        }
        if (options == null) rethrow;
      }

      if (!options.hasAny) {
        throw StateError('Server returned no transport options');
      }

      final family = SgtpTransportFamilyCodec.resolve(_config.transport);
      var tls = _config.useTls;
      if (tls && !options.supports(family, tls: true)) tls = false;
      if (!options.supports(family, tls: tls)) {
        throw StateError(
          'Transport not supported by server. Available: ${options.availableLabels().join(", ")}',
        );
      }
      final port = options.portFor(family, tls: tls);
      if (port <= 0 || port > 65535) {
        throw StateError('Invalid port for selected transport: $port');
      }

      _transport =
          _buildTransport(host: host, port: port, family: family, tls: tls);
      await _transport!.connect();

      _state = _ClientState.waitingHandshake;
      _eventController.add(SgtpHandshaking());
      AppLogger.i('Performing handshake...', tag: 'SGTP');
      _transport!.inbound.listen(
        _onData,
        onError: _onTransportError,
        onDone: _onTransportDone,
        cancelOnError: false,
      );
      _stalePruneTimer = Timer.periodic(
          Duration(seconds: _config.pingIntervalSeconds),
          (_) =>
              _pruneStale(thresholdMs: _config.pingIntervalSeconds * 3 * 1000));

      // Actively ping all known peers every interval so both sides stay alive
      // even when no messages are sent (fixes "peer left" when idle).
      _keepaliveTimer = Timer.periodic(
          Duration(seconds: _config.pingIntervalSeconds),
          (_) => _sendKeepalive());
      _handshakeRetryTimer?.cancel();
      _handshakeRetryTimer = Timer.periodic(const Duration(seconds: 2), (_) {
        if (_state != _ClientState.waitingHandshake || _readyEmitted) return;
        unawaited(_retryHandshakeProgress());
      });
      await _sendFrame(buildIntentFrame(_roomUUID, _myUUID));
      Future.delayed(Duration(milliseconds: SgtpConstants.infoDelayMs),
          () async {
        if (_state == _ClientState.waitingHandshake &&
            _peers.isEmpty &&
            !_readyEmitted) {
          AppLogger.i('No peers after delay — ready solo', tag: 'SGTP');
          _updateMaster();
          _chatRequestSent = true;
          await _issueCK();
        }
      });
    } catch (e) {
      _state = _ClientState.disconnected;
      AppLogger.e('Connection failed: $e', tag: 'SGTP');
      _eventController.add(SgtpError(error: 'Connection failed: $e'));
    }
  }

  (String host, int port) _parseHostPortOrThrow(String raw) {
    final s = raw
        .trim()
        .replaceAll(RegExp(r'^https?://', caseSensitive: false), '')
        .replaceAll(RegExp(r'^wss?://', caseSensitive: false), '')
        .trim();
    if (s.isEmpty) {
      throw ArgumentError('Empty server address');
    }

    if (s.startsWith('[')) {
      final end = s.indexOf(']');
      if (end <= 1) throw ArgumentError('Invalid IPv6 address: $raw');
      final host = s.substring(1, end);
      final rest = s.substring(end + 1);
      final port =
          (rest.startsWith(':') ? int.tryParse(rest.substring(1)) : null) ?? 0;
      if (port <= 0 || port > 65535) {
        throw ArgumentError('Invalid port in server address: $raw');
      }
      return (host, port);
    }

    final idx = s.lastIndexOf(':');
    if (idx <= 0 || idx == s.length - 1) {
      return (s, 443);
    }
    final host = s.substring(0, idx).trim();
    final port = int.tryParse(s.substring(idx + 1).trim()) ?? 0;
    if (host.isEmpty) {
      throw ArgumentError('Invalid host in server address: $raw');
    }
    if (port <= 0 || port > 65535) {
      throw ArgumentError('Invalid port in server address: $raw');
    }
    return (host, port);
  }

  SgtpTransport _buildTransport({
    required String host,
    required int port,
    required SgtpTransportFamily family,
    required bool tls,
  }) {
    return switch (family) {
      SgtpTransportFamily.tcp => TcpSgtpTransport(
          host: host,
          port: port,
          useTls: tls,
        ),
      SgtpTransportFamily.http => HttpSgtpTransport(
          host: host,
          port: port,
          useTls: tls,
        ),
      SgtpTransportFamily.websocket => WebSocketSgtpTransport(
          host: host,
          port: port,
          useTls: tls,
        ),
    };
  }

  Future<void> sendMessage(
    String text, {
    String? replyToId,
    String? replyToContent,
    String? replyToSender,
  }) async {
    if (_state != _ClientState.ready || _chatKey == null) return;
    final msgUUID = generateUUIDv7();
    final nonce = _myNonce++;
    final myPubHex = _hex(_config.myPublicKey);
    final payload = <String, dynamic>{
      'v': 1,
      'type': 'text',
      'text': text,
      'pub': myPubHex,
      if (replyToId != null) 'reply_to_id': replyToId,
      if (replyToContent != null) 'reply_to_content': replyToContent,
      if (replyToSender != null) 'reply_to_sender': replyToSender,
    };
    _attachChatAvatar(payload);
    final plaintext = Uint8List.fromList(utf8.encode(json.encode(payload)));
    try {
      final cipher = await encrypt(plaintext, _chatKey!, nonce);
      await _sendFrame(
          buildMessage(_roomUUID, _myUUID, msgUUID, nonce, cipher));
      unawaited(_persistRecord(_HistoryRecord(
        senderUUID: _myUUID,
        messageUUID: msgUUID,
        timestamp: DateTime.now().millisecondsSinceEpoch,
        nonce: nonce,
        plaintext: plaintext,
      )));
      _eventController.add(SgtpMessageReceived(
          message: ChatMessage(
        id: uuidBytesToHex(msgUUID),
        senderUUID: uuidBytesToHex(_myUUID),
        senderPublicKeyHex: myPubHex,
        content: text,
        receivedAt: DateTime.now(),
        isFromHistory: false,
        isFromMe: true,
        replyToId: replyToId,
        replyToContent: replyToContent,
        replyToSender: replyToSender,
      )));
    } catch (e) {
      AppLogger.e('Failed to send message: $e', tag: 'SGTP');
      _eventController.add(SgtpError(error: 'Failed to send message: $e'));
    }
  }

  /// Send an emoji reaction on a message. Peers receive it and update their UI.
  Future<void> sendReaction(String messageId, String emoji, bool add) async {
    if (_state != _ClientState.ready || _chatKey == null) return;
    try {
      final payload = <String, dynamic>{
        'v': 1,
        'type': 'reaction',
        'msg_id': messageId,
        'emoji': emoji,
        'add': add,
        'pub': _hex(_config.myPublicKey),
      };
      _attachChatAvatar(payload);
      final msgUUID = generateUUIDv7();
      final nonce = _myNonce++;
      final plain = Uint8List.fromList(utf8.encode(json.encode(payload)));
      final cipher = await encrypt(plain, _chatKey!, nonce);
      await _sendFrame(
          buildMessage(_roomUUID, _myUUID, msgUUID, nonce, cipher));
    } catch (_) {}
  }

  /// Send a read receipt for a given message ID.
  Future<void> sendMessageRead(String messageId) async {
    if (_state != _ClientState.ready || _chatKey == null) return;
    try {
      final payload = <String, dynamic>{
        'v': 1,
        'type': 'message_read',
        'msg_id': messageId,
        'pub': _hex(_config.myPublicKey),
      };
      _attachChatAvatar(payload);
      final msgUUID = generateUUIDv7();
      final nonce = _myNonce++;
      final plain = Uint8List.fromList(utf8.encode(json.encode(payload)));
      final cipher = await encrypt(plain, _chatKey!, nonce);
      await _sendFrame(
          buildMessage(_roomUUID, _myUUID, msgUUID, nonce, cipher));
    } catch (_) {}
  }

  /// Broadcast updated chat name/avatar to all peers via encrypted message.
  Future<void> sendChatMeta(String name, Uint8List? avatar) async {
    _currentChatName = name;
    _currentChatAvatar = avatar;
    if (_state != _ClientState.ready || _chatKey == null) return;
    try {
      final payload = <String, dynamic>{
        'v': 1,
        'type': 'chat_meta',
        'name': name,
        if (avatar != null && avatar.isNotEmpty)
          'avatar': base64.encode(avatar),
      };
      final msgUUID = generateUUIDv7();
      final nonce = _myNonce++;
      final plain = Uint8List.fromList(utf8.encode(json.encode(payload)));
      final cipher = await encrypt(plain, _chatKey!, nonce);
      await _sendFrame(
          buildMessage(_roomUUID, _myUUID, msgUUID, nonce, cipher));
      AppLogger.d('Sent chat_meta: $name', tag: 'SGTP');
    } catch (e) {
      AppLogger.e('sendChatMeta error: $e', tag: 'SGTP');
    }
  }

  /// Core send loop shared by all media senders.
  ///
  /// [totalSize] is the byte length of the full media.
  /// [readChunk] is called with (start, end) and must return exactly
  /// (end – start) bytes read from whatever backing store the caller has.
  /// Only that slice is held in RAM during each iteration.
  Future<void> _sendMediaChunked(String name, String mime, String mediaType,
      int totalSize, Future<Uint8List> Function(int start, int end) readChunk,
      {ChatMessage? echoMessage,
      void Function(double progress)? onProgress,
      Map<String, dynamic>? extraPayload,
      bool persistChunks = true}) async {
    if (_state != _ClientState.ready || _chatKey == null) return;
    // Web signing/encryption overhead per frame is noticeably higher.
    // Use larger chunks there to avoid multi-second pauses between chunks.
    final chunkSize = kIsWeb
        ? max(_config.mediaChunkSizeBytes, 512 * 1024)
        : _config.mediaChunkSizeBytes;
    final fileId = echoMessage?.id ?? uuidBytesToHex(generateUUIDv7());
    final totalChunks = (totalSize / chunkSize).ceil().clamp(1, 9999);

    // Emit echo immediately so the sender sees the bubble right away.
    // The echo id IS the fileId so read-receipts from receivers will match.
    if (echoMessage != null) {
      _eventController.add(SgtpMessageReceived(
          message: echoMessage.copyWith(
              id: fileId, isSending: true, sendProgress: 0.0)));
    }

    try {
      final progressTimer = Stopwatch()..start();
      var lastProgressEmit = 0.0;
      var lastProgressEmitMs = -1;
      for (int i = 0; i < totalChunks; i++) {
        final start = i * chunkSize;
        final end = (start + chunkSize).clamp(0, totalSize);
        // Read only this chunk — no other bytes are held in RAM.
        final chunkBytes = await readChunk(start, end);
        final Map<String, dynamic> payload = {
          'v': 1,
          'type': mediaType,
          'file_id': fileId,
          'name': name,
          'mime': mime,
          'size': totalSize,
          'data': base64.encode(chunkBytes),
        };
        if (i == 0) {
          _attachChatAvatar(payload);
          if (extraPayload != null && extraPayload.isNotEmpty) {
            payload.addAll(extraPayload);
          }
        }
        if (totalChunks > 1) {
          payload['chunk'] = i;
          payload['chunks'] = totalChunks;
        }
        final msgUUID = generateUUIDv7();
        final nonce = _myNonce++;
        final plain = Uint8List.fromList(utf8.encode(json.encode(payload)));
        final cipher = await encrypt(plain, _chatKey!, nonce);
        await _sendFrame(
            buildMessage(_roomUUID, _myUUID, msgUUID, nonce, cipher));
        if (persistChunks) {
          unawaited(_persistRecord(_HistoryRecord(
            senderUUID: _myUUID,
            messageUUID: msgUUID,
            timestamp: DateTime.now().millisecondsSinceEpoch,
            nonce: nonce,
            plaintext: plain,
          )));
        }

        // Report progress
        final progress = (i + 1) / totalChunks;
        onProgress?.call(progress);
        if (echoMessage != null) {
          final nowMs = progressTimer.elapsedMilliseconds;
          final shouldEmit = progress >= 1.0 ||
              (progress - lastProgressEmit) >= 0.03 ||
              lastProgressEmitMs < 0 ||
              (nowMs - lastProgressEmitMs) >= 200;
          if (shouldEmit) {
            lastProgressEmit = progress;
            lastProgressEmitMs = nowMs;
            _eventController.add(SgtpMediaProgress(
              messageId: fileId,
              echoId: fileId,
              progress: progress,
            ));
          }
        }

        // Yield periodically so UI isolate stays responsive on large media.
        if ((i & 1) == 1) {
          await Future<void>.delayed(Duration.zero);
        }
      }
      // Mark as sent
      if (echoMessage != null) {
        _eventController.add(SgtpMessageReceived(
            message: echoMessage.copyWith(
                id: fileId, isSending: false, sendProgress: 1.0)));
      }
    } catch (e) {
      AppLogger.e('Failed to send $mediaType: $e', tag: 'SGTP');
      _eventController.add(SgtpError(error: 'Failed to send $mediaType: $e'));
    }
  }

  /// Send media from an in-memory buffer (images, voice, short video notes).
  Future<void> _sendMedia(
          Uint8List bytes, String name, String mime, String mediaType,
          {ChatMessage? echoMessage,
          Map<String, dynamic>? extraPayload,
          void Function(double progress)? onProgress}) =>
      _sendMediaChunked(
        name,
        mime,
        mediaType,
        bytes.length,
        (start, end) async => Uint8List.sublistView(bytes, start, end),
        echoMessage: echoMessage,
        extraPayload: extraPayload,
        onProgress: onProgress,
      );

  /// Send media from an [XFile] with a read-ahead buffer.
  ///
  /// Reads [_sendReadAheadBytes] from disk at a time, then serves individual
  /// protocol chunks as zero-copy sub-slices — reducing IO calls by ~300×
  /// while keeping at most ~30 MB in RAM. Works on native and web.
  static const int _sendReadAheadBytes = 30 * 1024 * 1024; // 30 MB

  Future<void> _sendMediaFromXFile(
      XFile xFile, String name, String mime, String mediaType,
      {ChatMessage? echoMessage,
      Map<String, dynamic>? extraPayload,
      void Function(double progress)? onProgress}) async {
    final fileSize = await xFile.length();

    Uint8List? block;
    int blockStart = -1;

    await _sendMediaChunked(
      name, mime, mediaType, fileSize,
      (start, end) async {
        // Load the next 30 MB block when the current one is exhausted.
        if (block == null || start >= blockStart + block!.length) {
          final blockEnd = (start + _sendReadAheadBytes).clamp(0, fileSize);
          final builder = BytesBuilder(copy: false);
          await for (final part in xFile.openRead(start, blockEnd)) {
            builder.add(part);
          }
          block = builder.takeBytes();
          blockStart = start;
        }
        // Zero-copy slice from the in-memory block — no IO.
        final lo = start - blockStart;
        final hi = (end - blockStart).clamp(0, block!.length);
        return Uint8List.sublistView(block!, lo, hi);
      },
      echoMessage: echoMessage,
      extraPayload: extraPayload,
      onProgress: onProgress,
      // Media chunks are already cached to disk — persisting 2000+ JSON records
      // per file wastes disk I/O without any replay benefit.
      persistChunks: false,
    );
  }

  Future<void> sendImage(Uint8List bytes, String name, String mime) =>
      _sendMedia(bytes, name, mime, mime == 'image/gif' ? 'gif' : 'image',
          echoMessage: ChatMessage(
              id: uuidBytesToHex(generateUUIDv7()),
              senderUUID: uuidBytesToHex(_myUUID),
              content: name,
              imageBytes: bytes,
              mediaMime: mime,
              mediaName: name,
              type: mime == 'image/gif' ? MessageType.gif : MessageType.image,
              receivedAt: DateTime.now(),
              isFromHistory: false,
              isFromMe: true));

  Future<void> sendVideo(XFile xFile, String name, String mime) async {
    final echoId = uuidBytesToHex(generateUUIDv7());
    final localPath = await _cachePlayableMediaFromXFile(echoId, mime, xFile);
    return _sendMediaFromXFile(
      xFile,
      name,
      mime,
      'video',
      echoMessage: ChatMessage(
        id: echoId,
        senderUUID: uuidBytesToHex(_myUUID),
        content: name,
        mediaMime: mime,
        mediaName: name,
        localMediaPath: localPath ?? xFile.path,
        type: MessageType.video,
        receivedAt: DateTime.now(),
        isFromHistory: false,
        isFromMe: true,
      ),
    );
  }

  Future<void> sendVoice(Uint8List bytes, String mime) {
    final name = 'voice_${DateTime.now().millisecondsSinceEpoch}.${_ext(mime)}';
    return () async {
      final echoId = uuidBytesToHex(generateUUIDv7());
      final localPath = await _cachePlayableMedia(echoId, mime, bytes);
      await _sendMedia(
        bytes,
        name,
        mime,
        'voice',
        echoMessage: ChatMessage(
          id: echoId,
          senderUUID: uuidBytesToHex(_myUUID),
          content: name,
          audioBytes: localPath == null ? bytes : null,
          mediaMime: mime,
          mediaName: name,
          localMediaPath: localPath,
          type: MessageType.voice,
          receivedAt: DateTime.now(),
          isFromHistory: false,
          isFromMe: true,
        ),
      );
    }();
  }

  /// Send a circular video note (кружок) from an in-memory buffer (recorder).
  Future<void> sendVideoNote(
    Uint8List bytes,
    String mime, {
    VideoNoteMetadata? metadata,
  }) {
    final name =
        'videonote_${DateTime.now().millisecondsSinceEpoch}.${_extForMime(mime)}';
    return () async {
      final echoId = uuidBytesToHex(generateUUIDv7());
      final localPath = await _cachePlayableMedia(echoId, mime, bytes);
      await _sendMedia(
        bytes,
        name,
        mime,
        'video_note',
        extraPayload: metadata?.toPayloadJson(),
        echoMessage: ChatMessage(
          id: echoId,
          senderUUID: uuidBytesToHex(_myUUID),
          content: name,
          videoBytes: localPath == null ? bytes : null,
          mediaMime: mime,
          mediaName: name,
          localMediaPath: localPath,
          videoNoteMetadata: metadata,
          type: MessageType.videoNote,
          receivedAt: DateTime.now(),
          isFromHistory: false,
          isFromMe: true,
        ),
      );
    }();
  }

  /// Send a circular video note from a file (picked from gallery) —
  /// streams from disk, never loads the full file into RAM.
  Future<void> sendVideoNoteFromXFile(
    XFile xFile,
    String mime, {
    VideoNoteMetadata? metadata,
  }) async {
    AppLogger.i(
      'sendVideoNoteFromXFile start: path=${xFile.path}, mime=$mime, '
      'meta=${metadata?.width}x${metadata?.height}, duration=${metadata?.durationMs}',
      tag: 'VIDEO',
    );
    final name =
        'videonote_${DateTime.now().millisecondsSinceEpoch}.${_extForMime(mime)}';
    final echoId = uuidBytesToHex(generateUUIDv7());
    final localPath = await _cachePlayableMediaFromXFile(echoId, mime, xFile);
    AppLogger.d('Video note cached locally: ${localPath ?? xFile.path}',
        tag: 'VIDEO');
    await _sendMediaFromXFile(
      xFile,
      name,
      mime,
      'video_note',
      extraPayload: metadata?.toPayloadJson(),
      echoMessage: ChatMessage(
        id: echoId,
        senderUUID: uuidBytesToHex(_myUUID),
        content: name,
        mediaMime: mime,
        mediaName: name,
        localMediaPath: localPath ?? xFile.path,
        videoNoteMetadata: metadata,
        type: MessageType.videoNote,
        receivedAt: DateTime.now(),
        isFromHistory: false,
        isFromMe: true,
      ),
    );
    AppLogger.i('sendVideoNoteFromXFile completed: $name', tag: 'VIDEO');
  }

  String _ext(String mime) => switch (mime) {
        'audio/m4a' => 'm4a',
        'audio/mp4' => 'm4a',
        'audio/x-m4a' => 'm4a',
        'audio/aac' => 'aac',
        'audio/mp4a-latm' => 'aac',
        'audio/opus' => 'opus',
        'audio/mpeg' => 'mp3',
        _ => 'audio',
      };

  Future<void> disconnect() async {
    if (_state == _ClientState.disconnected) return;
    try {
      if (_chatKey != null) {
        final nonce = _myNonce++;
        final tag = await encrypt(Uint8List(0), _chatKey!, nonce);
        await _sendFrame(
            buildFin(_roomUUID, _myUUID, nonce, tag.sublist(0, 16)));
      }
    } catch (_) {}
    await _cleanup();
  }

  /// Nudge the existing TCP session after app resume without tearing it down.
  /// We can't observe raw TCP ACKs from Dart, so we rely on a lightweight
  /// application-level keepalive and the socket's onDone/onError callbacks.
  Future<void> probeConnection() async {
    if (_state == _ClientState.disconnected) return;
    try {
      if (_state == _ClientState.ready) {
        for (final peer in _peers.values.toList()) {
          await _sendPing(peer.uuidBytes, version: peer.protocolVersion);
        }
      } else {
        // Before ready we may still need an announce frame to trigger initial
        // peer discovery in the room.
        await _sendFrame(buildIntentFrame(_roomUUID, _myUUID));
      }
      AppLogger.d('Sent connection probe on existing socket', tag: 'SGTP');
    } catch (e) {
      AppLogger.w('Connection probe failed: $e', tag: 'SGTP');
    }
  }

  // ---------------------------------------------------------------------------
  // Socket
  // ---------------------------------------------------------------------------

  void _onData(List<int> data) {
    _lastReceiveAt = DateTime.now();
    _receiveBuffer.addAll(data);
    _scheduleNextFrame();
  }

  void _onTransportError(Object e) {
    AppLogger.e('Transport error: $e', tag: 'SGTP');
    _eventController.add(SgtpError(error: 'Transport error: $e'));
    _cleanup();
  }

  void _onTransportDone() {
    if (_state != _ClientState.disconnected) {
      _cleanup();
      AppLogger.i('Disconnected from server', tag: 'SGTP');
      _eventController.add(SgtpDisconnected());
    }
  }

  // Extract and dispatch at most ONE frame, then schedule the next via the
  // chain. This means ParsedFrame objects are created one at a time — the raw
  // frame bytes (~150 KB for a media chunk) are never all in memory at once.
  void _scheduleNextFrame() {
    final r = tryExtractFrame(_receiveBuffer);
    if (r == null) return;
    _receiveBuffer.removeRange(0, r.bytesConsumed);
    _frameChain = _frameChain.then((_) async {
      try {
        await _dispatch(r.frame);
      } catch (e) {
        AppLogger.w('Frame error: $e', tag: 'SGTP');
      }
      // After this frame is fully processed, extract the next one (if any).
      _scheduleNextFrame();
    });
  }

  bool _tsOk(int ts) =>
      (DateTime.now().millisecondsSinceEpoch - ts).abs() <=
      SgtpConstants.timestampWindow;

  Future<void> _dispatch(ParsedFrame frame) async {
    if (!_tsOk(frame.timestamp)) {
      AppLogger.w(
        '← INBOUND ${_pktName(frame.packetType)} from ${uuidBytesToHex(frame.senderUUID).substring(0, 8)} '
        'DROPPED (timestamp out of window: ${frame.timestamp})',
        tag: 'PKT',
      );
      return;
    }
    if (frame.version != SgtpConstants.version) {
      AppLogger.w(
        '← INBOUND ${_pktName(frame.packetType)} from ${uuidBytesToHex(frame.senderUUID).substring(0, 8)} '
        'DROPPED (version mismatch: ${frame.version})',
        tag: 'PKT',
      );
      return;
    }
    final frameSender = uuidBytesToHex(frame.senderUUID);
    if (_peers.containsKey(frameSender)) {
      _peerLastSeen[frameSender] = DateTime.now().millisecondsSinceEpoch;
    }
    AppLogger.d(
      '← INBOUND  ${_pktName(frame.packetType).padRight(14)} '
      'from=${frameSender.substring(0, 8)}  '
      'payload=${frame.payloadLength}B',
      tag: 'PKT',
    );
    switch (frame.packetType) {
      case PacketType.intent:
        await _onIntent(frame);
      case PacketType.ping:
        await _onPing(frame);
      case PacketType.pong:
        await _onPong(frame);
      case PacketType.info:
        if (frame.payloadLength == 0)
          await _onInfoReq(frame);
        else
          await _onInfoResp(frame);
      case PacketType.chatRequest:
        if (_isMaster) await _onChatRequest(frame);
      case PacketType.chatKey:
        await _onChatKey(frame);
      case PacketType.chatKeyAck:
        break;
      case PacketType.message:
        await _onMessage(frame);
      case PacketType.messageFailed:
        await _onMsgFailed(frame);
      case PacketType.status:
        await _onStatus(frame);
      case PacketType.fin:
        await _onFin(frame);
      case PacketType.kicked:
        _onKicked(frame);
      case PacketType.hsir:
        await _onHsir(frame);
      case PacketType.hsi:
        await _onHsi(frame);
      case PacketType.hsr:
        await _onHsr(frame);
      case PacketType.hsra:
        await _onHsra(frame);
      default:
        break;
    }
  }

  // ---------------------------------------------------------------------------
  // Handshake
  // ---------------------------------------------------------------------------

  Future<void> _onIntent(ParsedFrame f) async {
    final h = uuidBytesToHex(f.senderUUID);
    if (h == myUUIDHex) return;
    // INTENT is a join/announce signal. Existing peers may occasionally
    // re-send it as a liveness probe; answering every repeated INTENT with a
    // fresh PING causes handshake storms under heavy traffic.
    final known = _peers[h];
    if (known != null && known.handshakeComplete) {
      _peerLastSeen[h] = DateTime.now().millisecondsSinceEpoch;
      return;
    }
    // Use configurable threshold (not hardcoded 30s) to avoid kicking
    // peers whose last ping happened to be at the interval boundary
    await _pruneStale(thresholdMs: _config.pingIntervalSeconds * 4 * 1000);
    await _sendPing(f.senderUUID);
  }

  Future<void> _pruneStale({int thresholdMs = 300 * 1000}) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final stale = _peers.keys.where((h) {
      final seen = _peerLastSeen[h] ?? 0;
      return now - seen > thresholdMs;
    }).toList();
    if (stale.isEmpty) return;
    for (final h in stale) {
      _peers.remove(h);
      _peerLastSeen.remove(h);
      _pendingHandshakes.remove(h);
      AppLogger.i('Peer left: \${h.substring(0,8)}', tag: 'SGTP');
      if (!_eventController.isClosed)
        AppLogger.i('Peer left: \${h.substring(0,8)}', tag: 'SGTP');
      if (!_eventController.isClosed)
        _eventController.add(SgtpPeerLeft(peerUUID: h));
    }
    if (_state == _ClientState.ready) {
      _updateMaster();
      if (_isMaster && _peers.isNotEmpty) {
        _chatRequestSent = true;
        await _issueCK();
      } else if (_isMaster && _peers.isEmpty) {
        _chatRequestSent = false;
      }
    }
  }

  Future<void> _onPing(ParsedFrame f) async {
    final h = uuidBytesToHex(f.senderUUID);
    if (h == myUUIDHex) return;
    if (f.payloadLength < SgtpConstants.pingPayloadMinLength) return;
    final ed = f.ed25519PubKey;
    final edH = _hex(ed);
    if (!_whitelist.contains(edH)) return;
    if (!await verifyFrame(f.raw, ed)) return;
    if (f.payloadLength >= SgtpConstants.pingPayloadLength) {
      final hello = ascii.decode(f.payload.sublist(64, 76), allowInvalid: true);
      if (hello != SgtpConstants.clientHello) return;
    }
    final rawSecret =
        await computeSharedSecret(_ephemeralX25519!, f.x25519PubKey);
    final ss = f.version >= 0x0002
        ? await deriveSharedKey(rawSecret, _roomUUID)
        : rawSecret;
    final prev = _peers[h];
    _peers[h] = PeerInfo(
        uuid: h,
        uuidBytes: Uint8List.fromList(f.senderUUID),
        ed25519PubKey: ed,
        sharedKey: ss,
        protocolVersion: f.version,
        handshakeComplete: prev?.handshakeComplete ?? false);
    _peerLastSeen[h] = DateTime.now().millisecondsSinceEpoch;
    await _sendPong(f.senderUUID, version: f.version);
    _scheduleInfo();
    // Only announce if we have NOT announced this peer yet this session.
    _peerPublicKeys[h] = edH;
    if (!_eventController.isClosed && !_announcedJoins.contains(h)) {
      _announcedJoins.add(h);
      AppLogger.i('Peer joined: \${h.substring(0,8)}', tag: 'SGTP');
      _eventController.add(SgtpPeerJoined(peerUUID: h, ed25519PubHex: edH));
    }
  }

  Future<void> _onPong(ParsedFrame f) async {
    final h = uuidBytesToHex(f.senderUUID);
    if (h == myUUIDHex) return;
    if (f.payloadLength < SgtpConstants.pingPayloadMinLength) return;
    final ed = f.ed25519PubKey;
    final edH = _hex(ed);
    if (!_whitelist.contains(edH)) return;
    if (!await verifyFrame(f.raw, ed)) return;
    if (f.payloadLength >= SgtpConstants.pingPayloadLength) {
      final hello = ascii.decode(f.payload.sublist(64, 76), allowInvalid: true);
      if (hello != SgtpConstants.clientHello) return;
    }
    final rawSecret =
        await computeSharedSecret(_ephemeralX25519!, f.x25519PubKey);
    final ss = f.version >= 0x0002
        ? await deriveSharedKey(rawSecret, _roomUUID)
        : rawSecret;
    _peers[h] = PeerInfo(
        uuid: h,
        uuidBytes: Uint8List.fromList(f.senderUUID),
        ed25519PubKey: ed,
        sharedKey: ss,
        protocolVersion: f.version,
        handshakeComplete: true);
    _peerLastSeen[h] = DateTime.now().millisecondsSinceEpoch;
    _pendingHandshakes.remove(h);
    _pendingHandshakeTimers.remove(h)?.cancel();
    _peerPublicKeys[h] = edH;
    if (!_eventController.isClosed && !_announcedJoins.contains(h)) {
      _announcedJoins.add(h);
      _eventController.add(SgtpPeerJoined(peerUUID: h, ed25519PubHex: edH));
    }
    if (_state == _ClientState.ready && _isMaster) {
      await _issueCK();
    } else {
      _scheduleInfo();
      await _checkChatReq();
    }
  }

  void _scheduleInfo() {
    if (_infoTimerStarted) return;
    _infoTimerStarted = true;
    Future.delayed(Duration(milliseconds: SgtpConstants.infoDelayMs), () async {
      if (_state == _ClientState.disconnected) return;
      _updateMaster();
      if (_isMaster) {
        await _checkChatReq();
        return;
      }
      final m = _masterPeer();
      if (m == null) return;
      await _sendFrame(buildInfoRequest(_roomUUID, m, _myUUID));
    });
  }

  Future<void> _onInfoReq(ParsedFrame f) async {
    final peers = _peers.values.map((p) => p.uuidBytes).toList()..add(_myUUID);
    await _sendFrame(
        buildInfoResponse(_roomUUID, f.senderUUID, _myUUID, peers));
  }

  Future<void> _onInfoResp(ParsedFrame f) async {
    bool any = false;
    for (final u in f.infoUUIDs) {
      final h = uuidBytesToHex(u);
      if (h == myUUIDHex || _peers.containsKey(h)) continue;
      _pendingHandshakes.add(h);
      _pendingHandshakeTimers[h]?.cancel();
      _pendingHandshakeTimers[h] = Timer(const Duration(seconds: 5), () async {
        if (_pendingHandshakes.remove(h)) {
          AppLogger.w(
            'Handshake probe timed out for ${h.substring(0, 8)}; continuing with reachable peers',
            tag: 'SGTP',
          );
          _pendingHandshakeTimers.remove(h)?.cancel();
          _pendingHandshakeTimers.remove(h);
          await _checkChatReq();
        }
      });
      await _sendPing(u);
      any = true;
    }
    if (!any) await _checkChatReq();
  }

  Future<void> _checkChatReq() async {
    if (_chatRequestSent || _pendingHandshakes.isNotEmpty) return;
    if (_peers.isNotEmpty &&
        !_peers.values.every((p) => p.sharedKey.isNotEmpty)) return;
    _updateMaster();
    if (!_isMaster) {
      final m = _masterPeer();
      if (m == null) return;
      // Include current chat metadata in CHAT_REQUEST
      await _sendFrame(buildChatRequest(
        _roomUUID,
        m,
        _myUUID,
        _peers.values.map((p) => p.uuidBytes).toList(),
        chatName: _currentChatName,
        chatAvatarBytes: _currentChatAvatar,
      ));
      _chatRequestSent = true;
      AppLogger.d('Sent CHAT_REQUEST name="$_currentChatName"', tag: 'SGTP');
    } else {
      _chatRequestSent = true;
      await _issueCK();
    }
  }

  Future<void> _retryHandshakeProgress() async {
    try {
      if (_state != _ClientState.waitingHandshake || _readyEmitted) return;
      if (_peers.isEmpty) {
        await _sendFrame(buildIntentFrame(_roomUUID, _myUUID));
        return;
      }
      await _checkChatReq();
      if (_state != _ClientState.waitingHandshake || _readyEmitted) return;
      _updateMaster();
      if (!_isMaster) {
        final m = _masterPeer();
        if (m != null) {
          await _sendFrame(buildInfoRequest(_roomUUID, m, _myUUID));
        }
      }
    } catch (e) {
      AppLogger.w('Handshake retry tick failed: $e', tag: 'SGTP');
    }
  }

  Future<void> _onChatRequest(ParsedFrame f) async {
    final sender = uuidBytesToHex(f.senderUUID);
    AppLogger.d('CHAT_REQUEST from $sender', tag: 'SGTP');
    final peer = _peers[sender];
    if (peer == null) return;
    if (!await verifyFrame(f.raw, peer.ed25519PubKey)) return;

    // Parse metadata from the extended CHAT_REQUEST
    final name = f.chatRequestName;
    final avatar = f.chatRequestAvatar;
    if (name != null) {
      debugPrint(
          '[SGTP] CHAT_REQUEST metadata: name="$name" avatar=${avatar?.length ?? 0}B');
      _eventController.add(SgtpChatMetadataReceived(
        chatName: name,
        avatarBytes: avatar,
        senderUUID: sender,
      ));
    }

    if (_chatKey != null) {
      await _issueCKToPeer(sender);
    } else {
      await _issueCK();
    }
    unawaited(sendChatMeta(_currentChatName, _currentChatAvatar));
  }

  Future<void> _issueCKToPeer(String peerHex) async {
    if (_chatKey == null) return;
    final peer = _peers[peerHex];
    if (peer == null || peer.sharedKey.isEmpty) return;
    try {
      final version = peer.protocolVersion;
      final nonce = version >= 0x0002 ? _randomUint64() : _chatEpoch;
      final enc = await encrypt(_chatKey!, peer.sharedKey, nonce);
      await _sendFrame(buildChatKey(
        _roomUUID,
        peer.uuidBytes,
        _myUUID,
        _chatEpoch,
        nonce,
        enc,
        version: version,
      ));
    } catch (e) {
      AppLogger.e('_issueCKToPeer failed for $peerHex: $e', tag: 'SGTP');
    }
  }

  Future<void> _issueCK() async {
    final key = Uint8List.fromList(
        List.generate(32, (_) => _secureRandom.nextInt(256)));
    _chatKey = key;
    final ts = DateTime.now().millisecondsSinceEpoch;
    _chatEpoch = ts > _chatEpoch ? ts : _chatEpoch + 1;
    _myNonce = 0;
    for (final peer in _peers.values) {
      if (peer.sharedKey.isEmpty) continue;
      try {
        final version = peer.protocolVersion;
        final nonce = version >= 0x0002 ? _randomUint64() : _chatEpoch;
        final enc = await encrypt(key, peer.sharedKey, nonce);
        await _sendFrame(buildChatKey(
          _roomUUID,
          peer.uuidBytes,
          _myUUID,
          _chatEpoch,
          nonce,
          enc,
          version: version,
        ));
      } catch (e) {
        AppLogger.e('issueCK encrypt failed for ${peer.uuid}: $e', tag: 'SGTP');
      }
    }
    if (!_readyEmitted) {
      _readyEmitted = true;
      _state = _ClientState.ready;
      _handshakeRetryTimer?.cancel();
      _handshakeRetryTimer = null;
      AppLogger.i('Ready (master) room=\${roomUUIDHex.substring(0,8)}',
          tag: 'SGTP');
      _eventController.add(SgtpReady(isMaster: true, roomUUIDHex: roomUUIDHex));
    }
    _ckRotationTimer?.cancel();
    _ckRotationTimer = Timer(
        const Duration(seconds: SgtpConstants.ckRotationInterval), _issueCK);
  }

  Future<void> _onChatKey(ParsedFrame f) async {
    final senderH = uuidBytesToHex(f.senderUUID);
    final peer = _peers[senderH];
    if (peer == null || peer.sharedKey.isEmpty) return;
    if (!await verifyFrame(f.raw, peer.ed25519PubKey)) return;
    final minLen = f.version >= 0x0002
        ? SgtpConstants.chatKeyPayloadLengthV2
        : SgtpConstants.chatKeyPayloadLengthV1;
    if (f.payloadLength < minLen) return;
    try {
      final dec = await decrypt(
          f.encryptedChatKey, peer.sharedKey, f.chatKeyEncryptionNonce);
      if (dec.length != 32) return;
      _chatKey = Uint8List.fromList(dec);
      _chatEpoch = f.epoch;
      _myNonce = 0;
      await _sendFrame(buildChatKeyAck(_roomUUID, f.senderUUID, _myUUID));
      if (!_readyEmitted) {
        _readyEmitted = true;
        _state = _ClientState.ready;
        _handshakeRetryTimer?.cancel();
        _handshakeRetryTimer = null;
        AppLogger.i('Ready (peer) room=\${roomUUIDHex.substring(0,8)}',
            tag: 'SGTP');
        _eventController
            .add(SgtpReady(isMaster: false, roomUUIDHex: roomUUIDHex));
        _requestHistory();
      }
    } catch (e) {
      AppLogger.e('Failed to decrypt CHAT_KEY: $e', tag: 'SGTP');
      _eventController.add(SgtpError(error: 'Failed to decrypt CHAT_KEY: $e'));
    }
  }

  // ---------------------------------------------------------------------------
  // Messages
  // ---------------------------------------------------------------------------

  Future<void> _onMessage(ParsedFrame f, {bool history = false}) async {
    if (_chatKey == null || f.payloadLength < 40) return;
    final sH = uuidBytesToHex(f.senderUUID);
    if (!history) {
      final peer = _peers[sH];
      if (peer == null) return;
      if (!await verifyFrame(f.raw, peer.ed25519PubKey)) return;
    }
    if (!history && sH == myUUIDHex) return;
    try {
      final plain =
          await decrypt(f.messageCiphertext, _chatKey!, f.messageNonce);
      unawaited(_persistRecord(_HistoryRecord(
        senderUUID: Uint8List.fromList(f.senderUUID),
        messageUUID: Uint8List.fromList(f.messageUUID),
        timestamp: f.timestamp,
        nonce: f.messageNonce,
        plaintext: plain,
      )));
      await _emitDecodedMessage(
        msgId: uuidBytesToHex(f.messageUUID),
        senderUUIDHex: sH,
        plaintext: plain,
        recvAt: history
            ? DateTime.fromMillisecondsSinceEpoch(f.timestamp)
            : DateTime.now(),
        history: history,
      );
    } catch (_) {}
  }

  Future<void> _emitRecordFromHistory(PersistedHistoryRecord record) async {
    final msgId = uuidBytesToHex(record.messageUUID);
    final sender = uuidBytesToHex(record.senderUUID);
    await _emitDecodedMessage(
      msgId: msgId,
      senderUUIDHex: sender,
      plaintext: record.plaintext,
      recvAt: DateTime.fromMillisecondsSinceEpoch(record.timestamp),
      history: true,
    );
  }

  Future<void> _emitDecodedMessage({
    required String msgId,
    required String senderUUIDHex,
    required Uint8List plaintext,
    required DateTime recvAt,
    required bool history,
  }) async {
    Map<String, dynamic>? p;
    try {
      p = json.decode(utf8.decode(plaintext)) as Map<String, dynamic>;
    } catch (_) {}
    if (p == null || p['v'] != 1) {
      final mine = _isOwnMessage(senderUUIDHex, null);
      _eventController.add(SgtpMessageReceived(
          message: ChatMessage(
              id: msgId,
              senderUUID: senderUUIDHex,
              content: utf8.decode(plaintext),
              receivedAt: recvAt,
              isFromHistory: history,
              isFromMe: mine)));
      return;
    }
    _maybeApplyChatAvatarFromPayload(p, senderUUIDHex, history);
    final senderPub = p['pub'] as String?;
    final mine = _isOwnMessage(senderUUIDHex, senderPub);
    if (senderPub != null && !history)
      _peerPublicKeys[senderUUIDHex] = senderPub;

    switch (p['type'] as String?) {
      case 'text':
        _eventController.add(SgtpMessageReceived(
            message: ChatMessage(
          id: msgId,
          senderUUID: senderUUIDHex,
          senderPublicKeyHex: senderPub ?? _peerPublicKeys[senderUUIDHex],
          content: (p['text'] as String?) ?? '',
          receivedAt: recvAt,
          isFromHistory: history,
          isFromMe: mine,
          replyToId: p['reply_to_id'] as String?,
          replyToContent: p['reply_to_content'] as String?,
          replyToSender: p['reply_to_sender'] as String?,
        )));
      case 'image':
        await _mediaPayload(msgId, senderUUIDHex, p, 'image', history, recvAt,
            senderPub: senderPub, isFromMe: mine);
      case 'gif':
        await _mediaPayload(msgId, senderUUIDHex, p, 'gif', history, recvAt,
            senderPub: senderPub, isFromMe: mine);
      case 'video':
        await _mediaPayload(msgId, senderUUIDHex, p, 'video', history, recvAt,
            senderPub: senderPub, isFromMe: mine);
      case 'video_note':
        await _mediaPayload(
            msgId, senderUUIDHex, p, 'video_note', history, recvAt,
            senderPub: senderPub, isFromMe: mine);
      case 'voice':
        await _mediaPayload(msgId, senderUUIDHex, p, 'voice', history, recvAt,
            senderPub: senderPub, isFromMe: mine);
      case 'message_read':
        if (!history) {
          final readMsgId = p['msg_id'] as String?;
          if (readMsgId != null) {
            _eventController.add(SgtpMessageReadReceived(
              readMessageId: readMsgId,
              readerUUID: senderUUIDHex,
              readerPublicKeyHex: senderPub ?? _peerPublicKeys[senderUUIDHex],
            ));
          }
        }
      case 'reaction':
        if (!history) {
          final msgId = p['msg_id'] as String?;
          final emoji = p['emoji'] as String?;
          final add = (p['add'] as bool?) ?? true;
          if (msgId != null && emoji != null) {
            _eventController.add(SgtpReactionReceived(
              messageId: msgId,
              emoji: emoji,
              senderUUID: senderUUIDHex,
              add: add,
            ));
          }
        }
      case 'chat_meta':
        if (!history) {
          final name = p['name'] as String? ?? 'Chat';
          final b64 = p['avatar'] as String?;
          final avatar = b64 != null ? base64.decode(b64) : null;
          _currentChatName = name;
          _currentChatAvatar = avatar;
          _eventController.add(SgtpChatMetadataReceived(
            chatName: name,
            avatarBytes: avatar,
            senderUUID: senderUUIDHex,
          ));
        }
    }
  }

  Future<void> _mediaPayload(
    String id,
    String sender,
    Map<String, dynamic> p,
    String type,
    bool history,
    DateTime recvAt, {
    String? senderPub,
    required bool isFromMe,
  }) async {
    final fileId = p['file_id'] as String? ?? id;
    final name = p['name'] as String? ?? 'file';
    final mime = p['mime'] as String? ?? 'application/octet-stream';
    final totalSize = (p['size'] as num?)?.toInt() ?? 0;
    final videoNoteMetadata =
        type == 'video_note' ? VideoNoteMetadata.fromPayloadJson(p) : null;
    final chunk = base64.decode(p['data'] as String? ?? '');
    final shouldCacheToDisk =
        type == 'video' || type == 'video_note' || type == 'voice';
    if (!p.containsKey('chunk')) {
      final localPath = shouldCacheToDisk
          ? await _cachePlayableMedia(fileId, mime, chunk)
          : null;
      // Single-chunk: use fileId as message id so it matches sender's echo id
      _eventController.add(SgtpMessageReceived(
          message: _media(
              fileId, sender, name, mime, type, chunk, history, recvAt,
              senderPub: senderPub,
              isFromMe: isFromMe,
              videoNoteMetadata: videoNoteMetadata,
              localMediaPath: localPath)));
      return;
    }
    final ci = (p['chunk'] as num).toInt();
    final ct = (p['chunks'] as num).toInt();

    // Initialise the pending file entry once — using a Future so concurrent
    // frame handlers (fire-and-forget) all await the same init future.
    if (!_pendingFiles.containsKey(fileId)) {
      _pendingFiles[fileId] = () async {
        String tempPath = '';
        if (shouldCacheToDisk && !kIsWeb) {
          final dir = await getTemporaryDirectory();
          final cacheDir = Directory('${dir.path}/sgtp_media_cache');
          if (!await cacheDir.exists()) {
            await cacheDir.create(recursive: true);
          }
          tempPath = '${cacheDir.path}/$fileId.${_extForMime(mime)}';
        }
        return _PendingFile.create(
          fileId: fileId,
          name: name,
          mime: mime,
          totalSize: totalSize,
          totalChunks: ct,
          senderUUID: sender,
          mediaType: type,
          videoNoteMetadata: videoNoteMetadata,
          useDisk: shouldCacheToDisk,
          tempPath: tempPath,
        );
      }();
    }
    final pf = await _pendingFiles[fileId]!;
    await pf.writeChunk(ci, chunk);

    if (pf.isComplete) {
      _pendingFiles.remove(fileId);
      await pf.close();

      // Disk-based: file is already assembled at tempPath — no RAM copy needed.
      // Memory-based: assemble from in-memory chunks (non-cacheable types).
      final String? localPath = pf.tempPath;
      final Uint8List bytes = localPath != null
          ? Uint8List(0)
          : (pf.assembleMemory() ?? Uint8List(0));

      _eventController.add(SgtpMessageReceived(
          message: _media(
              fileId, sender, name, mime, type, bytes, history, recvAt,
              senderPub: senderPub,
              isFromMe: isFromMe,
              videoNoteMetadata: pf.videoNoteMetadata,
              localMediaPath: localPath)));
    }
  }

  ChatMessage _media(String id, String sender, String name, String mime,
          String type, Uint8List bytes, bool history, DateTime recvAt,
          {String? senderPub,
          required bool isFromMe,
          VideoNoteMetadata? videoNoteMetadata,
          String? localMediaPath}) =>
      switch (type) {
        'gif' => ChatMessage(
            id: id,
            senderUUID: sender,
            senderPublicKeyHex: senderPub ?? _peerPublicKeys[sender],
            content: name,
            imageBytes: bytes,
            mediaMime: mime,
            mediaName: name,
            localMediaPath: localMediaPath,
            type: MessageType.gif,
            receivedAt: recvAt,
            isFromHistory: history,
            isFromMe: isFromMe),
        'video' => ChatMessage(
            id: id,
            senderUUID: sender,
            senderPublicKeyHex: senderPub ?? _peerPublicKeys[sender],
            content: name,
            videoBytes: localMediaPath == null ? bytes : null,
            mediaMime: mime,
            mediaName: name,
            localMediaPath: localMediaPath,
            type: MessageType.video,
            receivedAt: recvAt,
            isFromHistory: history,
            isFromMe: isFromMe),
        'video_note' => ChatMessage(
            id: id,
            senderUUID: sender,
            senderPublicKeyHex: senderPub ?? _peerPublicKeys[sender],
            content: name,
            videoBytes: localMediaPath == null ? bytes : null,
            mediaMime: mime,
            mediaName: name,
            localMediaPath: localMediaPath,
            videoNoteMetadata: videoNoteMetadata,
            type: MessageType.videoNote,
            receivedAt: recvAt,
            isFromHistory: history,
            isFromMe: isFromMe),
        'voice' => ChatMessage(
            id: id,
            senderUUID: sender,
            senderPublicKeyHex: senderPub ?? _peerPublicKeys[sender],
            content: name,
            audioBytes: localMediaPath == null ? bytes : null,
            mediaMime: mime,
            mediaName: name,
            localMediaPath: localMediaPath,
            type: MessageType.voice,
            receivedAt: recvAt,
            isFromHistory: history,
            isFromMe: isFromMe),
        _ => ChatMessage(
            id: id,
            senderUUID: sender,
            senderPublicKeyHex: senderPub ?? _peerPublicKeys[sender],
            content: name,
            imageBytes: bytes,
            mediaMime: mime,
            mediaName: name,
            localMediaPath: localMediaPath,
            type: MessageType.image,
            receivedAt: recvAt,
            isFromHistory: history,
            isFromMe: isFromMe),
      };

  Future<String?> _cachePlayableMedia(
      String fileId, String mime, Uint8List bytes) async {
    if (kIsWeb) return null;
    try {
      final dir = await getTemporaryDirectory();
      final cacheDir = Directory('${dir.path}/sgtp_media_cache');
      if (!await cacheDir.exists()) {
        await cacheDir.create(recursive: true);
      }
      final ext = _extForMime(mime);
      final file = File('${cacheDir.path}/$fileId.$ext');
      if (!await file.exists()) {
        final sink = file.openWrite();
        const step = 64 * 1024;
        var yieldedChunks = 0;
        for (var i = 0; i < bytes.length; i += step) {
          final end = (i + step).clamp(0, bytes.length);
          sink.add(Uint8List.sublistView(bytes, i, end));
          yieldedChunks++;
          if (yieldedChunks >= 4) {
            yieldedChunks = 0;
            await Future<void>.delayed(Duration.zero);
          }
        }
        await sink.flush();
        await sink.close();
      }
      return file.path;
    } catch (_) {
      return null;
    }
  }

  /// Cache a playable media file from an [XFile] stream.
  /// On native: copies to temp directory via streaming (no full-file RAM load).
  /// On web: returns the XFile path directly (blob URL — no disk caching needed).
  Future<String?> _cachePlayableMediaFromXFile(
      String fileId, String mime, XFile xFile) async {
    if (kIsWeb) {
      return xFile.path.isNotEmpty ? xFile.path : null;
    }
    try {
      final dir = await getTemporaryDirectory();
      final cacheDir = Directory('${dir.path}/sgtp_media_cache');
      if (!await cacheDir.exists()) {
        await cacheDir.create(recursive: true);
      }
      final ext = _extForMime(mime);
      final dest = File('${cacheDir.path}/$fileId.$ext');
      if (!await dest.exists()) {
        final sink = dest.openWrite();
        await sink.addStream(xFile.openRead());
        await sink.flush();
        await sink.close();
      }
      return dest.path;
    } catch (_) {
      return null;
    }
  }

  String _extForMime(String mime) => switch (mime) {
        'video/mp4' => 'mp4',
        'video/quicktime' => 'mov',
        'video/webm' => 'webm',
        'video/x-msvideo' => 'avi',
        'video/x-matroska' => 'mkv',
        'video/x-m4v' => 'm4v',
        'video/3gpp' => '3gp',
        'audio/m4a' => 'm4a',
        'audio/mp4' => 'm4a',
        'audio/x-m4a' => 'm4a',
        'audio/aac' => 'aac',
        'audio/mp4a-latm' => 'aac',
        'audio/opus' => 'opus',
        'audio/mpeg' => 'mp3',
        _ => 'bin',
      };

  bool _isOwnMessage(String senderUUIDHex, String? senderPub) {
    final myPub = _hex(_config.myPublicKey).toLowerCase();
    final pub = (senderPub ?? '').trim().toLowerCase();
    if (pub.isNotEmpty) {
      return pub == myPub;
    }
    // Fallback for legacy payloads without `pub`.
    return senderUUIDHex == myUUIDHex;
  }

  void _attachChatAvatar(Map<String, dynamic> payload) {
    final avatar = _currentChatAvatar;
    if (avatar != null && avatar.isNotEmpty) {
      payload['chat_avatar'] = base64.encode(avatar);
    }
  }

  void _maybeApplyChatAvatarFromPayload(
      Map<String, dynamic> payload, String senderUUID, bool history) {
    final b64 = payload['chat_avatar'] as String?;
    if (b64 == null || b64.isEmpty) return;
    Uint8List avatar;
    try {
      avatar = Uint8List.fromList(base64.decode(b64));
    } catch (_) {
      return;
    }
    if (_bytesEqual(_currentChatAvatar, avatar)) return;
    _currentChatAvatar = avatar;
    if (!history) {
      _eventController.add(SgtpChatMetadataReceived(
        chatName: _currentChatName,
        avatarBytes: avatar,
        senderUUID: senderUUID,
      ));
    }
  }

  bool _bytesEqual(Uint8List? a, Uint8List? b) {
    if (a == null || b == null) return a == b;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  Future<void> _persistRecord(_HistoryRecord record) async {
    final repo = _historyRepository;
    if (repo == null) return;
    try {
      await repo.appendIfAbsent(PersistedHistoryRecord(
        senderUUID: record.senderUUID,
        messageUUID: record.messageUUID,
        timestamp: record.timestamp,
        nonce: record.nonce,
        plaintext: record.plaintext,
      ));
    } catch (_) {}
  }

  // ---------------------------------------------------------------------------
  // History: serve
  // ---------------------------------------------------------------------------

  Future<void> _onHsir(ParsedFrame f) async {
    final h = uuidBytesToHex(f.senderUUID);
    if (h == myUUIDHex) return;
    final peer = _peers[h];
    if (peer == null) return;
    if (!await verifyFrame(f.raw, peer.ed25519PubKey)) return;
    final historyCount = await persistedHistoryCount();
    await _sendFrame(buildHsi(
        _roomUUID, Uint8List.fromList(f.senderUUID), _myUUID, historyCount));
  }

  Future<void> _onHsr(ParsedFrame f) async {
    final recv = Uint8List.fromList(f.senderUUID);
    final senderHex = uuidBytesToHex(f.senderUUID);
    final peer = _peers[senderHex];
    if (peer == null) return;
    if (!await verifyFrame(f.raw, peer.ed25519PubKey)) return;
    if (_chatKey == null) {
      await _sendFrame(buildHsraEos(_roomUUID, recv, _myUUID, 0));
      return;
    }
    int offset = 0, limit = 0;
    if (f.payloadLength >= 16) {
      final bd = ByteData.view(f.payload.buffer, f.payload.offsetInBytes);
      offset = bdGetUint64(bd, 0, Endian.big);
      limit = bdGetUint64(bd, 8, Endian.big);
    }
    final repo = _historyRepository;
    if (repo == null) {
      await _sendFrame(buildHsraEos(_roomUUID, recv, _myUUID, 0));
      return;
    }
    final total = await repo.count();
    if (offset >= total) {
      await _sendFrame(buildHsraEos(_roomUUID, recv, _myUUID, 0));
      return;
    }
    final size = limit > 0 ? limit : (total - offset);
    final toServe = await repo.readRange(offset: offset, limit: size);
    const batch = 32;
    int batchNum = 0;
    for (var i = 0; i < toServe.length; i += batch) {
      final slice = toServe.skip(i).take(batch).toList();
      final frames = <Uint8List>[];
      for (final r in slice) {
        try {
          final nonce = _histNonceBit | r.nonce;
          final cipher = await encrypt(r.plaintext, _chatKey!, nonce);
          final raw = buildMessage(_roomUUID, Uint8List.fromList(r.senderUUID),
              Uint8List.fromList(r.messageUUID), nonce, cipher);
          raw.setRange(16, 32, f.senderUUID);
          frames.add(await signFrame(raw, _config.identityKeyPair));
        } catch (_) {}
      }
      if (frames.isNotEmpty) {
        await _sendFrame(buildHsra(_roomUUID, recv, _myUUID, batchNum, frames));
        batchNum++;
      }
    }
    await _sendFrame(buildHsraEos(_roomUUID, recv, _myUUID, toServe.length));
  }

  // ---------------------------------------------------------------------------
  // History: request
  // ---------------------------------------------------------------------------

  void _requestHistory() {
    if (_historyRequested || _peers.isEmpty) return;
    _historyRequested = true;
    _hsiReplies.clear();
    unawaited(_sendFrame(buildHsir(_roomUUID, _myUUID)));
    _hsiTimer?.cancel();
    _hsiTimer = Timer(const Duration(seconds: 2), _sendHsr);
  }

  Future<void> _onHsi(ParsedFrame f) async {
    final h = uuidBytesToHex(f.senderUUID);
    if (h == myUUIDHex) return;
    final peer = _peers[h];
    if (peer == null) return;
    if (!await verifyFrame(f.raw, peer.ed25519PubKey)) return;
    _hsiReplies[h] = f.hsiMessageCount;
  }

  Future<void> _sendHsr() async {
    if (_hsiReplies.isEmpty) return;
    final best =
        _hsiReplies.entries.reduce((a, b) => a.value >= b.value ? a : b);
    if (best.value == 0) return;
    final peer = _peers[best.key];
    if (peer == null) return;
    await _sendFrame(buildHsr(_roomUUID, peer.uuidBytes, _myUUID, 0, 0));
  }

  Future<void> _onHsra(ParsedFrame f) async {
    final senderHex = uuidBytesToHex(f.senderUUID);
    final peer = _peers[senderHex];
    if (peer == null) return;
    if (!await verifyFrame(f.raw, peer.ed25519PubKey)) return;
    if (f.hsraIsEndOfStream) return;
    for (final raw in f.hsraExtractMessages) {
      final parsed = tryParseFrame(raw);
      if (parsed == null || parsed.packetType != PacketType.message) continue;
      await _onMessage(parsed, history: true);
    }
  }

  // ---------------------------------------------------------------------------
  // Other handlers
  // ---------------------------------------------------------------------------

  Future<void> _onMsgFailed(ParsedFrame f) async {
    final peer = _peers[uuidBytesToHex(f.senderUUID)];
    if (peer == null || peer.sharedKey.isEmpty) return;
    if (!await verifyFrame(f.raw, peer.ed25519PubKey)) return;
    try {
      final (nonce, ciphertext) = _sharedKeyCipherParams(f);
      final plain = await decrypt(ciphertext, peer.sharedKey, nonce);
      if (plain.length >= 16)
        _eventController
            .add(SgtpError(error: 'Message rejected (CK rotation)'));
      await _sendFrame(buildMessageFailedAck(_roomUUID, f.senderUUID, _myUUID));
    } catch (_) {}
  }

  Future<void> _onStatus(ParsedFrame f) async {
    final peer = _peers[uuidBytesToHex(f.senderUUID)];
    if (peer == null || peer.sharedKey.isEmpty) return;
    if (!await verifyFrame(f.raw, peer.ed25519PubKey)) return;
    try {
      final (nonce, ciphertext) = _sharedKeyCipherParams(f);
      final plain = await decrypt(ciphertext, peer.sharedKey, nonce);
      if (plain.length >= 2) {
        final code = ByteData.view(plain.buffer, plain.offsetInBytes, 2)
            .getUint16(0, Endian.big);
        AppLogger.e('Server status $code', tag: 'SGTP');
        _eventController.add(SgtpError(error: 'Server status $code'));
      }
    } catch (_) {}
  }

  Future<void> _onFin(ParsedFrame f) async {
    final h = uuidBytesToHex(f.senderUUID);
    if (h == myUUIDHex) return;
    final peer = _peers[h];
    if (peer == null) return;
    if (!await verifyFrame(f.raw, peer.ed25519PubKey)) return;
    if (_chatKey != null && f.payloadLength >= SgtpConstants.finPayloadLength) {
      try {
        await decrypt(f.finTag, _chatKey!, f.finNonce);
      } catch (_) {
        return;
      }
    }
    _peers.remove(h);
    _pendingHandshakes.remove(h);
    _pendingHandshakeTimers.remove(h)?.cancel();
    _peerLastSeen.remove(h);
    _announcedJoins.remove(h); // allow re-announce if they rejoin later
    _eventController.add(SgtpPeerLeft(peerUUID: h));
    if (_state == _ClientState.ready) {
      if (_peers.isEmpty) {
        _chatRequestSent = false;
      } else {
        _updateMaster();
        if (_isMaster) {
          _chatRequestSent = true;
          await _issueCK();
        }
      }
    }
  }

  void _onKicked(ParsedFrame f) {
    if (f.payloadLength < 16) return;
    final h = uuidBytesToHex(f.payload.sublist(0, 16));
    _peers.remove(h);
    _pendingHandshakes.remove(h);
    _pendingHandshakeTimers.remove(h)?.cancel();
    _eventController.add(SgtpPeerLeft(peerUUID: h));
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  (int nonce, Uint8List ciphertext) _sharedKeyCipherParams(ParsedFrame f) {
    if (f.version >= 0x0002 && f.payloadLength >= 8) {
      final bd = ByteData.view(f.payload.buffer, f.payload.offsetInBytes, 8);
      final nonce = bdGetUint64(bd, 0, Endian.big);
      final ciphertext = Uint8List.fromList(f.payload.sublist(8));
      return (nonce, ciphertext);
    }
    return (f.timestamp, f.payload);
  }

  int _randomUint64() {
    final bytes = Uint8List(8);
    for (var i = 0; i < 8; i++) {
      bytes[i] = _secureRandom.nextInt(256);
    }
    final bd = ByteData.view(bytes.buffer);
    return bdGetUint64(bd, 0, Endian.big);
  }

  Future<void> _sendPing(Uint8List r,
      {int version = SgtpConstants.version}) async {
    if (_ephemeralX25519Pub == null) return;
    await _sendFrame(buildPingFrame(
        _roomUUID, r, _myUUID, _ephemeralX25519Pub!, _config.myPublicKey,
        version: version));
  }

  /// Proactively ping every connected peer to keep connections alive.
  /// INTENT is sent only when we have no peers, so we avoid re-triggering
  /// handshake flows for already connected peers.
  Future<void> _sendKeepalive() async {
    if (_state != _ClientState.ready) return;
    if (_peers.isEmpty) {
      // Keep an idle room connection active without causing peer ping loops.
      await _sendFrame(buildIntentFrame(_roomUUID, _myUUID));
      return;
    }
    for (final peer in _peers.values.toList()) {
      await _sendPing(peer.uuidBytes, version: peer.protocolVersion);
    }
  }

  Future<void> _sendPong(Uint8List r,
      {int version = SgtpConstants.version}) async {
    if (_ephemeralX25519Pub == null) return;
    await _sendFrame(buildPongFrame(
        _roomUUID, r, _myUUID, _ephemeralX25519Pub!, _config.myPublicKey,
        version: version));
  }

  Future<void> _sendFrame(Uint8List unsigned) async {
    // Log outbound packet type (bytes 50–51 in header = packet type uint16BE).
    if (unsigned.length >= 52) {
      final pktType = (unsigned[50] << 8) | unsigned[51];
      final payloadLen = unsigned.length -
          SgtpConstants.headerSize -
          SgtpConstants.signatureSize;
      final recv = uuidBytesToHex(unsigned.sublist(16, 32)).substring(0, 8);
      AppLogger.d(
        '→ OUTBOUND ${_pktName(pktType).padRight(14)} '
        'to=${recv}  payload=${payloadLen}B',
        tag: 'PKT',
      );
    }
    // Sign first — this is CPU/async work, safe to do before entering the queue.
    final Uint8List signed;
    try {
      signed = await signFrame(unsigned, _config.identityKeyPair);
    } catch (e) {
      if (!_eventController.isClosed) {
        AppLogger.e('Failed to sign frame: $e', tag: 'SGTP');
        _eventController.add(SgtpError(error: 'Failed to sign frame: $e'));
      }
      return;
    }

    // Serialize socket writes: one frame at a time, in call order.
    // This prevents concurrent async sends from interleaving bytes in the
    // TCP stream (which would corrupt the length-prefix framing).
    final prev = _sendChain;
    final mine = Completer<void>();
    _sendChain = mine.future;

    try {
      await prev; // wait for the previous write to finish
    } catch (_) {} // ignore errors from previous sends — don't block the queue

    try {
      final t = _transport;
      if (t != null) await t.send(signed);
    } catch (e) {
      if (!_eventController.isClosed) {
        AppLogger.e('Failed to send frame: $e', tag: 'SGTP');
        _eventController.add(SgtpError(error: 'Failed to send frame: $e'));
      }
    } finally {
      mine.complete(); // release the next sender
    }
  }

  /// Human-readable name for a packet type code (for logging).
  static String _pktName(int type) => switch (type) {
        PacketType.intent => 'INTENT',
        PacketType.ping => 'PING',
        PacketType.pong => 'PONG',
        PacketType.info => 'INFO',
        PacketType.chatRequest => 'CHAT_REQUEST',
        PacketType.chatKey => 'CHAT_KEY',
        PacketType.chatKeyAck => 'CHAT_KEY_ACK',
        PacketType.message => 'MESSAGE',
        PacketType.messageFailed => 'MSG_FAILED',
        PacketType.messageFailedAck => 'MSG_FAILED_ACK',
        PacketType.status => 'STATUS',
        PacketType.fin => 'FIN',
        PacketType.kickRequest => 'KICK_REQ',
        PacketType.kicked => 'KICKED',
        PacketType.hsir => 'HSIR',
        PacketType.hsi => 'HSI',
        PacketType.hsr => 'HSR',
        PacketType.hsra => 'HSRA',
        _ => '0x${type.toRadixString(16).padLeft(4, '0')}',
      };

  void _updateMaster() {
    _isMaster =
        _peers.values.every((p) => compareBytes(p.uuidBytes, _myUUID) > 0);
  }

  Uint8List? _masterPeer() {
    if (_peers.isEmpty) return null;
    Uint8List? s;
    for (final p in _peers.values) {
      if (s == null || compareBytes(p.uuidBytes, s) < 0) s = p.uuidBytes;
    }
    if (s != null && compareBytes(_myUUID, s) < 0) return null;
    return s;
  }

  String _hex(Uint8List b) =>
      b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

  Future<void> _cleanup() async {
    _state = _ClientState.disconnected;
    _ckRotationTimer?.cancel();
    _hsiTimer?.cancel();
    _stalePruneTimer?.cancel();
    _keepaliveTimer?.cancel();
    _handshakeRetryTimer?.cancel();
    _ckRotationTimer = null;
    _hsiTimer = null;
    _stalePruneTimer = null;
    _keepaliveTimer = null;
    _handshakeRetryTimer = null;
    _peerLastSeen.clear();
    _announcedJoins.clear();
    _infoTimerStarted = false;
    _chatRequestSent = false;
    _readyEmitted = false;
    _historyRequested = false;
    _isMaster = false;
    _peers.clear();
    _pendingHandshakes.clear();
    for (final timer in _pendingHandshakeTimers.values) {
      timer.cancel();
    }
    _pendingHandshakeTimers.clear();
    _frameChain = Future.value();
    for (final fut in _pendingFiles.values) {
      fut.then((pf) => pf.close()).catchError((_) {});
    }
    _pendingFiles.clear();
    _hsiReplies.clear();
    _peerPublicKeys.clear();
    _chatKey = null;
    _chatEpoch = 0;
    _myNonce = 0;
    _receiveBuffer.clear();
    _sendChain = Future.value(); // reset the send queue
    _lastReceiveAt = DateTime.now();
    try {
      await _transport?.close();
    } catch (_) {}
    _transport = null;
  }

  Future<void> close() async {
    await _cleanup();
    await _eventController.close();
  }
}
