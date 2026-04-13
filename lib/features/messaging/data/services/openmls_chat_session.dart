import 'dart:async';
import 'dart:convert' show base64, json, utf8, ascii;
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cross_file/cross_file.dart';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:path_provider/path_provider.dart';
import 'package:sgtp_chat_core/sgtp_chat_core.dart';

import 'package:sgtp_flutter/core/app_log.dart';
import 'package:sgtp_flutter/core/constants.dart';
import 'package:sgtp_flutter/core/uint64_utils.dart';
import 'package:sgtp_flutter/core/network/i_protocol_transport.dart';
import 'package:sgtp_flutter/core/sgtp_transport.dart';
import 'package:sgtp_flutter/core/crypto/chacha20_utils.dart';
import 'package:sgtp_flutter/core/crypto/ed25519_utils.dart';
import 'package:sgtp_flutter/core/crypto/x25519_utils.dart';
import 'package:sgtp_flutter/core/protocol/frame_builder.dart';
import 'package:sgtp_flutter/core/protocol/frame_parser.dart';
import 'package:sgtp_flutter/core/protocol/packet_types.dart';
import 'package:sgtp_flutter/core/uuid_v7.dart';
import 'package:sgtp_flutter/features/messaging/data/repositories/chat_history_repository.dart';
import 'package:sgtp_flutter/features/messaging/data/transport/http_sgtp_transport.dart';
import 'package:sgtp_flutter/features/messaging/data/transport/server_discovery.dart';
import 'package:sgtp_flutter/features/messaging/data/transport/tcp_sgtp_transport.dart';
import 'package:sgtp_flutter/features/messaging/data/transport/websocket_sgtp_transport.dart';
import 'package:sgtp_flutter/features/messaging/domain/entities/sgtp_config.dart';
import 'package:sgtp_flutter/features/messaging/domain/entities/message.dart';
import 'package:sgtp_flutter/features/messaging/domain/entities/peer.dart';
import 'package:sgtp_flutter/features/messaging/domain/entities/video_note_metadata.dart';
import 'package:sgtp_flutter/features/messaging/domain/repositories/i_sgtp_session.dart';

export 'package:sgtp_flutter/features/messaging/domain/repositories/i_sgtp_session.dart';

/// Legacy class name retained as a deprecated alias for compatibility.
const String kLegacySgtpClientDeprecationMessage =
    'Legacy class name. Use OpenMlsChatSession for the active chat_core/'
    'OpenMLS-backed chat runtime.';

final _log = AppLog('OpenMlsChatSession');
final _logVideo = AppLog('VideoNote');

String _sgtpLogQuote(String value) {
  final escaped = value
      .replaceAll(r'\', r'\\')
      .replaceAll('"', r'\"')
      .replaceAll('\n', r'\n');
  return '"$escaped"';
}

String _sgtpLogStringValue(String value, {int maxBytes = 120}) {
  final bytes = utf8.encode(value);
  if (bytes.length > maxBytes) {
    return '<${bytes.length} bytes>';
  }
  return _sgtpLogQuote(value);
}

String _sgtpLogValue(Object? value) {
  if (value == null) return 'null';
  if (value is String) return _sgtpLogStringValue(value);
  if (value is Uint8List) return '<${value.length} bytes>';
  if (value is bool || value is num) return '$value';
  if (value is Iterable) {
    final items = value.toList(growable: false);
    if (items.length > 5) return '<${items.length} items>';
    return '[${items.map(_sgtpLogValue).join(', ')}]';
  }
  return _sgtpLogStringValue(value.toString());
}

void _sgtpLogCall(String method, [Map<String, Object?> args = const {}]) {
  if (args.isEmpty) {
    _log.debug('{method}()', parameters: {'method': method});
    return;
  }
  final formatted =
      args.entries.map((e) => '${e.key}=${_sgtpLogValue(e.value)}').join(', ');
  _log.debug('{method}({args})',
      parameters: {'method': method, 'args': formatted});
}

String? _sgtpVideoNoteMetadataSummary(VideoNoteMetadata? metadata) {
  if (metadata == null) return null;
  return '${metadata.width}x${metadata.height}/${metadata.durationMs}ms';
}

const Set<String> _mlsTransportPayloadTypes = {
  'mls_key_package',
  'mls_welcome',
  'mls_commit',
  'mls_app',
};

String? _decodedPayloadType(Uint8List plaintext) {
  try {
    final decoded = json.decode(utf8.decode(plaintext));
    if (decoded is Map && decoded['v'] == 1) {
      return decoded['type'] as String?;
    }
  } catch (_) {}
  return null;
}

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
  String? senderPublicKeyHex;

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
    this.senderPublicKeyHex,
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
    String? senderPublicKeyHex,
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
        senderPublicKeyHex: senderPublicKeyHex,
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
      senderPublicKeyHex: senderPublicKeyHex,
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
// Client state
// ---------------------------------------------------------------------------

enum _ClientState { disconnected, connecting, waitingHandshake, ready }

// ---------------------------------------------------------------------------
// OpenMLS chat session
// ---------------------------------------------------------------------------

class OpenMlsChatSession implements ISgtpSession {
  final SgtpConfig _config;
  final Uint8List _myUUID;
  late final Uint8List _roomUUID;
  final Random _secureRandom = Random.secure();

  final _eventController = StreamController<SgtpEvent>.broadcast();
  @override
  Stream<SgtpEvent> get events => _eventController.stream;

  IProtocolTransport? _transport;
  final List<int> _receiveBuffer = [];
  _ClientState _state = _ClientState.disconnected;

  final Map<String, PeerInfo> _peers = {};
  SimpleKeyPair? _ephemeralX25519;
  Uint8List? _ephemeralX25519Pub;

  Uint8List? _chatKey;
  int _chatEpoch = 0;
  int _myNonce = 0;

  MessengerMls? _mls;
  bool _mlsClientReady = false;
  bool _mlsGroupReady = false;
  bool _mlsKeyPackageBroadcast = false;
  bool _mlsGroupCreated = false;
  bool _mlsInviteInFlight = false;
  String? _mlsLocalKeyPackageB64;
  final Map<String, String> _mlsPeerKeyPackages = {};
  final Set<String> _mlsInvitedPeers = {};

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
  final Map<String, int> _chatKeyAckEpochByPeer = {};
  final Map<String, int> _chatKeyRetryCountByPeer = {};
  final Map<String, Timer> _chatKeyRetryTimers = {};
  final Map<String, int> _needChatKeyLastSentMsByPeer = {};

  static const int _histNonceBit = 1 << 62;

  /// Timestamp of the last received bytes from the server.
  /// Used to detect stale TCP connections after returning from background.
  DateTime _lastReceiveAt = DateTime.now();

  OpenMlsChatSession(SgtpConfig config)
      : _config = config,
        _myUUID = generateUUIDv7(),
        _currentChatName = config.chatName,
        _currentChatAvatar = config.chatAvatarBytes {
    _roomUUID = config.roomUUID.every((b) => b == 0)
        ? generateUUIDv7()
        : Uint8List.fromList(config.roomUUID);
    _whitelist = _normalizeWhitelist(config.whitelist);
    _historyRepository = _buildHistoryRepository();
  }

  bool get isMaster => _isMaster;
  @override
  String get myUUIDHex => uuidBytesToHex(_myUUID);
  @override
  String get roomUUIDHex => uuidBytesToHex(_roomUUID);
  @override
  List<String> get peerUUIDs => _peers.keys.toList();

  /// Returns sessionUUID → ed25519PubHex for all ever-seen peers.
  @override
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
    _sgtpLogCall('persistedHistoryCount');
    final repo = _historyRepository;
    if (repo == null) return 0;
    return repo.count();
  }

  @override
  Future<PersistedHistoryBatchResult> replayPersistedHistoryBatch({
    required int offsetFromEnd,
    int limit = 100,
  }) async {
    _sgtpLogCall('replayPersistedHistoryBatch', {
      'offsetFromEnd': offsetFromEnd,
      'limit': limit,
    });
    final repo = _historyRepository;
    if (repo == null) {
      return const PersistedHistoryBatchResult(loaded: 0, total: 0);
    }
    final total = await repo.count();
    // Media messages are persisted chunk-by-chunk. A single video can span
    // hundreds of history records, so loading only the default 100 records may
    // return an incomplete tail of chunks and the video won't reconstruct.
    // For the initial open, pull a larger window to reliably include full media.
    final effectiveLimit = offsetFromEnd == 0 ? max(limit, 1200) : limit;
    final records = await repo.readBatchFromEnd(
      offsetFromEnd: offsetFromEnd,
      limit: effectiveLimit,
    );
    var loaded = records.length;
    for (final record in records) {
      await _emitRecordFromHistory(record);
    }

    // If initial history starts from the middle of a chunked media payload
    // (typical for large videos), keep backfilling older records until pending
    // media assembly completes or we hit a sane safety cap.
    if (offsetFromEnd == 0 && _pendingFiles.isNotEmpty) {
      const backfillStep = 400;
      const maxBackfillRecords = 8000;
      var backfilled = 0;

      while (_pendingFiles.isNotEmpty &&
          (offsetFromEnd + loaded) < total &&
          backfilled < maxBackfillRecords) {
        final take = min(backfillStep, maxBackfillRecords - backfilled);
        final older = await repo.readBatchFromEnd(
          offsetFromEnd: offsetFromEnd + loaded,
          limit: take,
        );
        if (older.isEmpty) break;
        for (final record in older) {
          await _emitRecordFromHistory(record);
        }
        loaded += older.length;
        backfilled += older.length;
      }

      // Avoid leaking temp pending-file handles if history ended mid-file.
      if (_pendingFiles.isNotEmpty) {
        final dangling = _pendingFiles.keys.toList();
        for (final fileId in dangling) {
          final fut = _pendingFiles.remove(fileId);
          fut?.then((pf) => pf.close()).catchError((_) {});
        }
      }
    }

    return PersistedHistoryBatchResult(loaded: loaded, total: total);
  }

  /// User avatar is local UI-only and is not exchanged in SGTP MESSAGE payloads.
  @override
  void setUserAvatar(Uint8List? avatar) {
    _sgtpLogCall('setUserAvatar', {'avatar': avatar});
  }

  /// Hot-update the peer whitelist without reconnecting.
  /// Newly added keys are accepted on the next ping/pong; removed keys are
  /// dropped at the next prune cycle.
  @override
  void updateWhitelist(Set<String> whitelist) {
    _sgtpLogCall('updateWhitelist', {'whitelistCount': whitelist.length});
    _whitelist = _normalizeWhitelist(whitelist);
  }

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  @override
  Future<void> connect() async {
    _sgtpLogCall('connect', {
      'serverAddress': _config.serverAddr,
      'transport': _config.transport.name,
      'useTls': _config.useTls,
    });
    if (_state != _ClientState.disconnected) return;
    _state = _ClientState.connecting;
    _eventController.add(SgtpConnecting());
    _log.info('Connecting to server...');
    try {
      await _initMls();
      _ephemeralX25519 = await generateEphemeralKeyPair();
      _ephemeralX25519Pub = await extractPublicKeyBytes(_ephemeralX25519!);
      final (host, explicitPort) = _parseHostPortOrThrow(_config.serverAddr);

      final result = await SgtpServerDiscovery.discover(
        host,
        preferredPort: explicitPort > 0 ? explicitPort : null,
        preferredTls: _config.useTls,
      );
      final options = result.opts;

      if (!options.hasAny) {
        throw StateError('Server returned no transport options');
      }

      final family = SgtpTransportFamilyCodec.resolve(_config.transport);
      final tls = _config.useTls;
      if (!options.supports(family, tls: tls)) {
        throw StateError(
          'Selected transport (${family.name}, tls=$tls) not supported by server. '
          'Available: ${options.availableLabels().join(", ")}',
        );
      }
      final port = options.portFor(family, tls: tls);
      if (port <= 0 || port > 65535) {
        throw StateError('Invalid port for selected transport: $port');
      }

      _transport = _buildTransport(
        host: host,
        port: port,
        family: family,
        tls: tls,
        fakeSni: _config.fakeSni,
      );
      await _transport!.connect();

      _state = _ClientState.waitingHandshake;
      _eventController.add(SgtpHandshaking());
      _log.info('Performing handshake...');
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
          _log.info('No peers after delay — ready solo');
          _updateMaster();
          _chatRequestSent = true;
          await _issueCK();
        }
      });
    } catch (e) {
      _state = _ClientState.disconnected;
      _log.error('Connection failed: {error}', parameters: {'error': e});
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

  IProtocolTransport _buildTransport({
    required String host,
    required int port,
    required SgtpTransportFamily family,
    required bool tls,
    String? fakeSni,
  }) {
    return switch (family) {
      SgtpTransportFamily.tcp => TcpSgtpTransport(
          host: host,
          port: port,
          useTls: tls,
          fakeSni: fakeSni,
        ),
      SgtpTransportFamily.http => HttpSgtpTransport(
          host: host,
          port: port,
          useTls: tls,
          fakeSni: fakeSni,
        ),
      SgtpTransportFamily.websocket => WebSocketSgtpTransport(
          host: host,
          port: port,
          useTls: tls,
          fakeSni: fakeSni,
        ),
    };
  }

  Future<void> _initMls() async {
    if (_mlsClientReady) return;
    try {
      final privateKey = await _config.identityKeyPair.extractPrivateKeyBytes();
      final userId =
          (_config.accountId ?? _config.nodeId ?? _hex(_config.myPublicKey))
              .trim();
      final deviceId = myUUIDHex;
      final clientId = {
        'user_id': userId.isEmpty ? _hex(_config.myPublicKey) : userId,
        'device_id': deviceId,
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
      final bundle = mls.createKeyPackagesSync(8);
      final keyPackages = _asObjectList(_map(bundle)['keypackages']);
      if (keyPackages.isEmpty) {
        throw StateError('chat_core returned no key packages');
      }
      final first = _asBytes(keyPackages.first);
      _mls = mls;
      _mlsLocalKeyPackageB64 = base64.encode(first);
      _mlsClientReady = true;
      _log.info('MLS client initialized');
    } catch (e) {
      _mls?.close();
      _mls = null;
      _mlsClientReady = false;
      _log.warning(
          'MLS initialization failed; continuing with transport-level chat encryption only: {error}',
          parameters: {'error': e});
    }
  }

  Map<String, dynamic> _map(Object? value) {
    if (value is Map<String, dynamic>) return value;
    if (value is Map) return value.map((key, value) => MapEntry('$key', value));
    return <String, dynamic>{};
  }

  List<Object?> _asObjectList(Object? value) {
    if (value is List) return value.cast<Object?>();
    return const [];
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

  Map<String, dynamic> get _mlsGroupIdJson => {'value': _roomUUID};

  Future<void> _ensureMlsGroupCreated() async {
    if (!_mlsClientReady || _mlsGroupCreated) return;
    final mls = _mls;
    if (mls == null) return;
    try {
      mls.createGroupSync(_mlsGroupIdJson);
      _mlsGroupCreated = true;
      _mlsGroupReady = true;
      _log.info('MLS group created');
    } on MlsException catch (e) {
      // Already-created groups can happen after reconnects within the same process.
      if (!e.message.toLowerCase().contains('exists')) rethrow;
      _mlsGroupCreated = true;
      _mlsGroupReady = true;
    }
  }

  Future<void> _announceMlsKeyPackage() async {
    if (!_mlsClientReady || _mlsKeyPackageBroadcast || _chatKey == null) return;
    final keyPackageB64 = _mlsLocalKeyPackageB64;
    if (keyPackageB64 == null || keyPackageB64.isEmpty) return;
    _mlsKeyPackageBroadcast = true;
    await _sendLegacyPayload({
      'v': 1,
      'type': 'mls_key_package',
      'pub': _hex(_config.myPublicKey),
      'client_id': {
        'user_id':
            (_config.accountId ?? _config.nodeId ?? _hex(_config.myPublicKey))
                .trim(),
        'device_id': myUUIDHex,
      },
      'keypackage': keyPackageB64,
    });
  }

  Future<void> _inviteKnownMlsPeers() async {
    if (!_isMaster ||
        !_mlsClientReady ||
        !_mlsGroupReady ||
        _mlsInviteInFlight) {
      return;
    }
    final mls = _mls;
    if (mls == null || _chatKey == null) return;
    _mlsInviteInFlight = true;
    try {
      for (final entry in _mlsPeerKeyPackages.entries.toList()) {
        final peerHex = entry.key;
        if (_mlsInvitedPeers.contains(peerHex)) continue;
        final peer = _peers[peerHex];
        if (peer == null) continue;
        final keyPackage = base64.decode(entry.value);
        final result = _map(mls.inviteSync({
          'group_id': _mlsGroupIdJson,
          'invited_client': {
            'user_id': _peerPublicKeys[peerHex] ?? peerHex,
            'device_id': peerHex,
          },
          'keypackage': keyPackage,
        }));
        _mlsInvitedPeers.add(peerHex);
        final welcome = _asBytes(result['welcome_message']);
        final commit = _asBytes(result['commit_message']);
        if (welcome.isNotEmpty) {
          await _sendLegacyPayload({
            'v': 1,
            'type': 'mls_welcome',
            'to': peerHex,
            'payload': base64.encode(welcome),
          });
        }
        if (commit.isNotEmpty) {
          await _sendLegacyPayload({
            'v': 1,
            'type': 'mls_commit',
            'payload': base64.encode(commit),
          });
        }
        try {
          mls.mergePendingCommitSync(_mlsGroupIdJson);
        } catch (e) {
          _log.warning('MLS pending commit merge failed: {error}',
              parameters: {'error': e});
        }
      }
    } catch (e) {
      _log.warning('MLS invite failed: {error}', parameters: {'error': e});
    } finally {
      _mlsInviteInFlight = false;
    }
  }

  Future<Uint8List?> _mlsEncryptPayload(Uint8List plaintext) async {
    final mls = _mls;
    if (mls == null || !_mlsGroupReady) return null;
    try {
      final encrypted = mls.encryptMessageSync({
        'group_id': _mlsGroupIdJson,
        'plaintext': plaintext,
        'aad': _roomUUID,
      });
      return _asBytes(encrypted);
    } catch (e) {
      _log.warning('MLS encrypt failed; using transport envelope payload: {error}',
          parameters: {'error': e});
      return null;
    }
  }

  Future<Uint8List?> _mlsHandleGroupMessage(Uint8List payload) async {
    final mls = _mls;
    if (mls == null || !_mlsClientReady) return null;
    try {
      final result = mls.handleIncomingSync({
        'kind': 'GroupMessage',
        'payload': payload,
      });
      final events = result is List ? _asObjectList(result) : <Object?>[result];
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
        }
      }
    } catch (e) {
      _log.warning('MLS incoming group message failed: {error}',
          parameters: {'error': e});
    }
    return null;
  }

  Future<int?> _sendLegacyPayload(
    Map<String, dynamic> payload, {
    Uint8List? messageUUID,
    bool persist = false,
  }) async {
    if (_state != _ClientState.ready || _chatKey == null) return null;
    final msgUUID = messageUUID ?? generateUUIDv7();
    final nonce = _myNonce++;
    final plain = Uint8List.fromList(utf8.encode(json.encode(payload)));
    final cipher = await encrypt(plain, _chatKey!, nonce);
    await _sendFrame(buildMessage(_roomUUID, _myUUID, msgUUID, nonce, cipher));
    if (persist) {
      unawaited(_persistRecord(_HistoryRecord(
        senderUUID: _myUUID,
        messageUUID: msgUUID,
        timestamp: DateTime.now().millisecondsSinceEpoch,
        nonce: nonce,
        plaintext: plain,
      )));
    }
    return nonce;
  }

  Future<int?> _sendApplicationPayload(
    Map<String, dynamic> payload, {
    Uint8List? messageUUID,
    bool persist = false,
  }) async {
    final plain = Uint8List.fromList(utf8.encode(json.encode(payload)));
    final mlsCiphertext = await _mlsEncryptPayload(plain);
    if (mlsCiphertext == null) {
      return _sendLegacyPayload(payload,
          messageUUID: messageUUID, persist: persist);
    }
    return _sendLegacyPayload({
      'v': 1,
      'type': 'mls_app',
      'payload': base64.encode(mlsCiphertext),
    }, messageUUID: messageUUID, persist: persist);
  }

  @override
  Future<void> sendMessage(
    String text, {
    String? replyToId,
    String? replyToContent,
    String? replyToSender,
  }) async {
    _sgtpLogCall('sendMessage', {
      'text': text,
      if (replyToId != null) 'replyToId': replyToId,
      if (replyToContent != null) 'replyToContent': replyToContent,
      if (replyToSender != null) 'replyToSender': replyToSender,
    });
    if (_state != _ClientState.ready || _chatKey == null) return;
    final msgUUID = generateUUIDv7();
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
      final nonce =
          await _sendApplicationPayload(payload, messageUUID: msgUUID);
      if (nonce == null) return;
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
      _log.error('Failed to send message: {error}', parameters: {'error': e});
      _eventController.add(SgtpError(error: 'Failed to send message: $e'));
    }
  }

  /// Send an emoji reaction on a message. Peers receive it and update their UI.
  @override
  Future<void> sendReaction(String messageId, String emoji, bool add) async {
    _sgtpLogCall('sendReaction', {
      'messageId': messageId,
      'emoji': emoji,
      'add': add,
    });
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
      await _sendApplicationPayload(payload);
    } catch (_) {}
  }

  /// Send a read receipt for a given message ID.
  @override
  Future<void> sendMessageRead(String messageId) async {
    _sgtpLogCall('sendMessageRead', {'messageId': messageId});
    if (_state != _ClientState.ready || _chatKey == null) return;
    try {
      final payload = <String, dynamic>{
        'v': 1,
        'type': 'message_read',
        'msg_id': messageId,
        'pub': _hex(_config.myPublicKey),
      };
      _attachChatAvatar(payload);
      await _sendApplicationPayload(payload);
    } catch (_) {}
  }

  /// Broadcast updated chat name/avatar to all peers via encrypted message.
  @override
  Future<void> sendChatMeta(String name, Uint8List? avatar) async {
    _sgtpLogCall('sendChatMeta', {'name': name, 'avatar': avatar});
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
      await _sendApplicationPayload(payload);
      _log.debug('Sent chat_meta: {name}', parameters: {'name': name});
    } catch (e) {
      _log.error('sendChatMeta error: {error}', parameters: {'error': e});
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
    final myPubHex = _hex(_config.myPublicKey);

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
        final end = (start + chunkSize).clamp(0, totalSize).toInt();
        // Read only this chunk — no other bytes are held in RAM.
        final chunkBytes = await readChunk(start, end);
        final Map<String, dynamic> payload = {
          'v': 1,
          'type': mediaType,
          'pub': myPubHex,
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
        final plain = Uint8List.fromList(utf8.encode(json.encode(payload)));
        final nonce =
            await _sendApplicationPayload(payload, messageUUID: msgUUID);
        if (persistChunks && nonce != null) {
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
      _log.error('Failed to send {mediaType}: {error}',
          parameters: {'mediaType': mediaType, 'error': e});
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
      // Persist XFile-based media chunks too.
      // Otherwise messages are visible only in current RAM session and can
      // disappear from history after process/device restart.
      persistChunks: true,
    );
  }

  @override
  Future<void> sendImage(Uint8List bytes, String name, String mime) async {
    _sgtpLogCall('sendImage', {
      'bytes': bytes,
      'name': name,
      'mime': mime,
    });
    return _sendMedia(
      bytes,
      name,
      mime,
      mime == 'image/gif' ? 'gif' : 'image',
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
        isFromMe: true,
      ),
    );
  }

  @override
  Future<void> sendVideo(XFile xFile, String name, String mime) async {
    _sgtpLogCall('sendVideo', {
      'filePath': xFile.path,
      'name': name,
      'mime': mime,
    });
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

  @override
  Future<void> sendVoice(Uint8List bytes, String mime) {
    _sgtpLogCall('sendVoice', {'bytes': bytes, 'mime': mime});
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
  @override
  Future<void> sendVideoNote(
    Uint8List bytes,
    String mime, {
    VideoNoteMetadata? metadata,
  }) {
    _sgtpLogCall('sendVideoNote', {
      'bytes': bytes,
      'mime': mime,
      'metadata': _sgtpVideoNoteMetadataSummary(metadata),
    });
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
  @override
  Future<void> sendVideoNoteFromXFile(
    XFile xFile,
    String mime, {
    VideoNoteMetadata? metadata,
  }) async {
    _sgtpLogCall('sendVideoNoteFromXFile', {
      'filePath': xFile.path,
      'mime': mime,
      'metadata': _sgtpVideoNoteMetadataSummary(metadata),
    });
    _logVideo.info(
        'sendVideoNoteFromXFile start: path=${xFile.path}, mime=$mime, '
        'meta=${metadata?.width}x${metadata?.height}, duration=${metadata?.durationMs}');
    final name =
        'videonote_${DateTime.now().millisecondsSinceEpoch}.${_extForMime(mime)}';
    final echoId = uuidBytesToHex(generateUUIDv7());
    final localPath = await _cachePlayableMediaFromXFile(echoId, mime, xFile);
    _logVideo.debug('Video note cached locally: ${localPath ?? xFile.path}');
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
    _logVideo.info('sendVideoNoteFromXFile completed: $name');
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

  @override
  Future<void> disconnect() async {
    _sgtpLogCall('disconnect');
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
  @override
  Future<void> probeConnection() async {
    _sgtpLogCall('probeConnection');
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
      _log.debug('Sent connection probe on existing socket');
    } catch (e) {
      _log.warning('Connection probe failed: {error}',
          parameters: {'error': e});
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
    _log.error('Transport error: {error}', parameters: {'error': e});
    _eventController.add(SgtpError(error: 'Transport error: $e'));
    _cleanup();
  }

  void _onTransportDone() {
    if (_state != _ClientState.disconnected) {
      _cleanup();
      _log.info('Disconnected from server');
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
        _log.warning('Frame error: {error}', parameters: {'error': e});
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
      _log.warning(
        'Dropping frame outside timestamp window: pkt={packetType} sender={sender}',
        parameters: {
          'packetType': frame.packetType,
          'sender': uuidBytesToHex(frame.senderUUID).substring(0, 8),
        },
      );
      return;
    }
    if (frame.version != SgtpConstants.version) {
      _log.warning(
        'Dropping frame with unsupported version: version={version} sender={sender}',
        parameters: {
          'version': frame.version,
          'sender': uuidBytesToHex(frame.senderUUID).substring(0, 8),
        },
      );
      return;
    }
    if (!_bytesEqual(frame.roomUUID, _roomUUID)) {
      _log.warning(
        'Dropping frame for another room: frameRoom={frameRoom} localRoom={localRoom}',
        parameters: {
          'frameRoom': uuidBytesToHex(frame.roomUUID).substring(0, 8),
          'localRoom': roomUUIDHex.substring(0, 8),
        },
      );
      return;
    }
    final receiverHex = uuidBytesToHex(frame.receiverUUID);
    final isBroadcast = _bytesEqual(frame.receiverUUID, SgtpConstants.broadcastUUID);
    if (!isBroadcast && receiverHex != myUUIDHex) {
      _log.warning(
        'Dropping frame addressed to another peer: receiver={receiver} local={local}',
        parameters: {
          'receiver': receiverHex.substring(0, 8),
          'local': myUUIDHex.substring(0, 8),
        },
      );
      return;
    }
    final frameSender = uuidBytesToHex(frame.senderUUID);
    if (_peers.containsKey(frameSender)) {
      _peerLastSeen[frameSender] = DateTime.now().millisecondsSinceEpoch;
    }
    switch (frame.packetType) {
      case PacketType.intent:
        await _onIntent(frame);
        break;
      case PacketType.ping:
        await _onPing(frame);
        break;
      case PacketType.pong:
        await _onPong(frame);
        break;
      case PacketType.info:
        if (frame.payloadLength == 0) {
          await _onInfoReq(frame);
        } else {
          await _onInfoResp(frame);
        }
        break;
      case PacketType.chatRequest:
        if (_isMaster) await _onChatRequest(frame);
        break;
      case PacketType.chatKey:
        await _onChatKey(frame);
        break;
      case PacketType.chatKeyAck:
        await _onChatKeyAck(frame);
        break;
      case PacketType.message:
        await _onMessage(frame);
        break;
      case PacketType.messageFailed:
        await _onMsgFailed(frame);
        break;
      case PacketType.status:
        await _onStatus(frame);
        break;
      case PacketType.fin:
        await _onFin(frame);
        break;
      case PacketType.kicked:
        _onKicked(frame);
        break;
      case PacketType.hsir:
        await _onHsir(frame);
        break;
      case PacketType.hsi:
        await _onHsi(frame);
        break;
      case PacketType.hsr:
        await _onHsr(frame);
        break;
      case PacketType.hsra:
        await _onHsra(frame);
        break;
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
      if (_isMaster && _state == _ClientState.ready) {
        await _ensureChatKeyForPeer(h);
      }
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
      _chatKeyAckEpochByPeer.remove(h);
      _chatKeyRetryCountByPeer.remove(h);
      _chatKeyRetryTimers.remove(h)?.cancel();
      _needChatKeyLastSentMsByPeer.remove(h);
      _log.info('Peer left: {peer}', parameters: {'peer': h.substring(0, 8)});
      if (!_eventController.isClosed) {
        _log.info('Peer left: {peer}', parameters: {'peer': h.substring(0, 8)});
      }
      if (!_eventController.isClosed) {
        _eventController.add(SgtpPeerLeft(peerUUID: h));
      }
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
    if (f.payloadLength < SgtpConstants.pingPayloadMinLength) {
      _log.warning('Dropping short PING from {peer}',
          parameters: {'peer': h.substring(0, 8)});
      return;
    }
    final ed = f.ed25519PubKey;
    final edH = _hex(ed);
    if (!_whitelist.contains(edH)) {
      _log.warning('Rejecting PING from non-whitelisted peer {peer} pub={pub}',
          parameters: {'peer': h.substring(0, 8), 'pub': edH.substring(0, 8)});
      return;
    }
    if (!await verifyFrame(f.raw, ed)) {
      _log.warning('Rejecting PING with bad signature from {peer}',
          parameters: {'peer': h.substring(0, 8)});
      return;
    }
    if (f.payloadLength >= SgtpConstants.pingPayloadLength) {
      final hello = ascii.decode(f.payload.sublist(64, 76), allowInvalid: true);
      if (hello != SgtpConstants.clientHello) {
        _log.warning('Rejecting PING with invalid hello from {peer}',
            parameters: {'peer': h.substring(0, 8)});
        return;
      }
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
      _log.info('Peer joined: {peer}', parameters: {'peer': h.substring(0, 8)});
      _eventController.add(SgtpPeerJoined(peerUUID: h, ed25519PubHex: edH));
    }
  }

  Future<void> _onPong(ParsedFrame f) async {
    final h = uuidBytesToHex(f.senderUUID);
    if (h == myUUIDHex) return;
    if (f.payloadLength < SgtpConstants.pingPayloadMinLength) {
      _log.warning('Dropping short PONG from {peer}',
          parameters: {'peer': h.substring(0, 8)});
      return;
    }
    final ed = f.ed25519PubKey;
    final edH = _hex(ed);
    if (!_whitelist.contains(edH)) {
      _log.warning('Rejecting PONG from non-whitelisted peer {peer} pub={pub}',
          parameters: {'peer': h.substring(0, 8), 'pub': edH.substring(0, 8)});
      return;
    }
    if (!await verifyFrame(f.raw, ed)) {
      _log.warning('Rejecting PONG with bad signature from {peer}',
          parameters: {'peer': h.substring(0, 8)});
      return;
    }
    if (f.payloadLength >= SgtpConstants.pingPayloadLength) {
      final hello = ascii.decode(f.payload.sublist(64, 76), allowInvalid: true);
      if (hello != SgtpConstants.clientHello) {
        _log.warning('Rejecting PONG with invalid hello from {peer}',
            parameters: {'peer': h.substring(0, 8)});
        return;
      }
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
      await _ensureChatKeyForPeer(h);
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
          _log.warning(
              'Handshake probe timed out for {peer}; continuing with reachable peers',
              parameters: {'peer': h.substring(0, 8)});
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
        !_peers.values.every((p) => p.sharedKey.isNotEmpty)) {
      return;
    }
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
      _log.debug('Sent CHAT_REQUEST name="{name}"',
          parameters: {'name': _currentChatName});
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
      _log.warning('Handshake retry tick failed: {error}',
          parameters: {'error': e});
    }
  }

  Future<void> _onChatRequest(ParsedFrame f) async {
    final sender = uuidBytesToHex(f.senderUUID);
    _log.debug('CHAT_REQUEST from {sender}', parameters: {'sender': sender});
    final peer = _peers[sender];
    if (peer == null) return;
    if (!await verifyFrame(f.raw, peer.ed25519PubKey)) return;

    // Parse metadata from the extended CHAT_REQUEST
    final name = f.chatRequestName;
    final avatar = f.chatRequestAvatar;
    if (name != null) {
      _log.debug('CHAT_REQUEST metadata: name="{name}" avatar={avatarSize}B',
          parameters: {'name': name, 'avatarSize': avatar?.length ?? 0});
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
      _scheduleChatKeyRetry(peerHex);
    } catch (e) {
      _log.error('_issueCKToPeer failed for {peer}: {error}',
          parameters: {'peer': peerHex, 'error': e});
    }
  }

  bool _isChatKeyAckedForCurrentEpoch(String peerHex) {
    return _chatKeyAckEpochByPeer[peerHex] == _chatEpoch;
  }

  Future<void> _ensureChatKeyForPeer(String peerHex) async {
    if (!_isMaster || _chatKey == null) return;
    final peer = _peers[peerHex];
    if (peer == null || peer.sharedKey.isEmpty) return;
    if (_isChatKeyAckedForCurrentEpoch(peerHex)) return;
    await _issueCKToPeer(peerHex);
  }

  void _scheduleChatKeyRetry(String peerHex) {
    _chatKeyRetryTimers.remove(peerHex)?.cancel();
    _chatKeyRetryTimers[peerHex] = Timer(
      const Duration(seconds: SgtpConstants.ckAckTimeoutSeconds),
      () async {
        if (_state == _ClientState.disconnected || !_isMaster) return;
        if (_isChatKeyAckedForCurrentEpoch(peerHex)) return;
        final retries = (_chatKeyRetryCountByPeer[peerHex] ?? 0) + 1;
        if (retries > SgtpConstants.ckAckRetries) {
          _chatKeyRetryCountByPeer.remove(peerHex);
          _chatKeyRetryTimers.remove(peerHex)?.cancel();
          _log.warning(
              'CHAT_KEY retry budget exhausted for {peer} epoch={epoch}',
              parameters: {
                'peer': peerHex.substring(0, 8),
                'epoch': _chatEpoch
              });
          return;
        }
        _chatKeyRetryCountByPeer[peerHex] = retries;
        await _issueCKToPeer(peerHex);
      },
    );
  }

  Future<void> _issueCK() async {
    final key = Uint8List.fromList(
        List.generate(32, (_) => _secureRandom.nextInt(256)));
    _chatKey = key;
    final ts = DateTime.now().millisecondsSinceEpoch;
    _chatEpoch = ts > _chatEpoch ? ts : _chatEpoch + 1;
    _myNonce = 0;
    _chatKeyRetryTimers.forEach((_, t) => t.cancel());
    _chatKeyRetryTimers.clear();
    _chatKeyRetryCountByPeer.clear();
    for (final peer in _peers.values) {
      if (peer.sharedKey.isEmpty) continue;
      try {
        _chatKeyAckEpochByPeer.remove(peer.uuid);
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
        _scheduleChatKeyRetry(peer.uuid);
      } catch (e) {
        _log.error('issueCK encrypt failed for {peer}: {error}',
            parameters: {'peer': peer.uuid, 'error': e});
      }
    }
    if (!_readyEmitted) {
      _readyEmitted = true;
      _state = _ClientState.ready;
      _handshakeRetryTimer?.cancel();
      _handshakeRetryTimer = null;
      _log.info('Ready (master) room={room}',
          parameters: {'room': roomUUIDHex.substring(0, 8)});
      _eventController.add(SgtpReady(isMaster: true, roomUUIDHex: roomUUIDHex));
      unawaited(_onLegacyReadyForMls());
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
      await _sendFrame(buildChatKeyAck(
        _roomUUID,
        f.senderUUID,
        _myUUID,
        f.epoch,
        version: f.version,
      ));
      if (!_readyEmitted) {
        _readyEmitted = true;
        _state = _ClientState.ready;
        _handshakeRetryTimer?.cancel();
        _handshakeRetryTimer = null;
        _log.info('Ready (peer) room={room}',
            parameters: {'room': roomUUIDHex.substring(0, 8)});
        _eventController
            .add(SgtpReady(isMaster: false, roomUUIDHex: roomUUIDHex));
        unawaited(_onLegacyReadyForMls());
        _requestHistory();
      }
    } catch (e) {
      // Rapid focus/background switches can race old/new handshakes.
      // In that case stale CHAT_KEY frames may fail MAC check transiently.
      // Recover silently by re-running handshake instead of spamming UI errors.
      _log.warning('CHAT_KEY decrypt failed (will recover): {error}',
          parameters: {'error': e});
      await _recoverFromChatKeyDecryptFailure(f.senderUUID);
    }
  }

  Future<void> _onChatKeyAck(ParsedFrame f) async {
    if (!_isMaster) return;
    final senderH = uuidBytesToHex(f.senderUUID);
    final peer = _peers[senderH];
    if (peer == null) return;
    if (!await verifyFrame(f.raw, peer.ed25519PubKey)) return;
    final ackEpoch = f.chatKeyAckEpoch ?? _chatEpoch;
    if (ackEpoch != _chatEpoch) {
      return;
    }
    _chatKeyAckEpochByPeer[senderH] = ackEpoch;
    _chatKeyRetryCountByPeer.remove(senderH);
    _chatKeyRetryTimers.remove(senderH)?.cancel();
  }

  Future<void> _onLegacyReadyForMls() async {
    if (!_mlsClientReady || _chatKey == null) return;
    try {
      if (_isMaster) {
        await _ensureMlsGroupCreated();
        await _inviteKnownMlsPeers();
      } else {
        await _announceMlsKeyPackage();
      }
    } catch (e) {
      _log.warning('MLS ready hook failed: {error}', parameters: {'error': e});
    }
  }

  Future<void> _recoverFromChatKeyDecryptFailure(Uint8List senderUUID) async {
    try {
      final h = uuidBytesToHex(senderUUID);
      _chatKey = null;
      _chatRequestSent = false;
      _pendingHandshakes.add(h);
      _pendingHandshakeTimers[h]?.cancel();
      _pendingHandshakeTimers[h] = Timer(const Duration(seconds: 5), () async {
        if (_pendingHandshakes.remove(h)) {
          _pendingHandshakeTimers.remove(h)?.cancel();
          _pendingHandshakeTimers.remove(h);
          await _checkChatReq();
        }
      });
      await _sendPing(senderUUID);
      // Trigger a fresh key exchange after shared-secret re-derivation.
      await _checkChatReq();
    } catch (e) {
      _log.warning('CHAT_KEY recovery failed: {error}',
          parameters: {'error': e});
    }
  }

  // ---------------------------------------------------------------------------
  // Messages
  // ---------------------------------------------------------------------------

  Future<void> _onMessage(ParsedFrame f, {bool history = false}) async {
    if (_chatKey == null || f.payloadLength < 40) {
      if (!history) {
        await _sendNeedChatKeyIfNeeded(uuidBytesToHex(f.senderUUID));
      }
      return;
    }
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
      final record = _HistoryRecord(
        senderUUID: Uint8List.fromList(f.senderUUID),
        messageUUID: Uint8List.fromList(f.messageUUID),
        timestamp: f.timestamp,
        nonce: f.messageNonce,
        plaintext: plain,
      );
      final payloadType = _decodedPayloadType(plain);
      if (!history && !_mlsTransportPayloadTypes.contains(payloadType)) {
        unawaited(_persistRecord(record));
      }
      await _emitDecodedMessage(
        msgId: uuidBytesToHex(f.messageUUID),
        senderUUIDHex: sH,
        plaintext: plain,
        recvAt: history
            ? DateTime.fromMillisecondsSinceEpoch(f.timestamp)
            : DateTime.now(),
        history: history,
        decodedPersistRecord:
            !history && payloadType == 'mls_app' ? record : null,
      );
    } catch (_) {
      if (!history) {
        await _sendNeedChatKeyIfNeeded(sH);
      }
    }
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
    _HistoryRecord? decodedPersistRecord,
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
    if (senderPub != null) _peerPublicKeys[senderUUIDHex] = senderPub;

    switch (p['type'] as String?) {
      case 'mls_key_package':
        if (!history && _isMaster && senderUUIDHex != myUUIDHex) {
          final kp = p['keypackage'] as String?;
          if (kp != null && kp.isNotEmpty) {
            _mlsPeerKeyPackages[senderUUIDHex] = kp;
            await _inviteKnownMlsPeers();
          }
        }
      case 'mls_welcome':
        if (!history && !_isMaster && !_mlsGroupReady) {
          final to = (p['to'] as String?)?.toLowerCase();
          if (to == null || to == myUUIDHex.toLowerCase()) {
            final payload = p['payload'] as String?;
            if (payload != null) {
              try {
                _mls?.joinFromWelcomeSync(base64.decode(payload));
                _mlsGroupReady = true;
                _log.info('MLS group joined');
              } catch (e) {
                _log.warning('MLS welcome failed: {error}',
                    parameters: {'error': e});
              }
            }
          }
        }
      case 'mls_commit':
        if (!history && senderUUIDHex != myUUIDHex) {
          final payload = p['payload'] as String?;
          if (payload != null) {
            await _mlsHandleGroupMessage(base64.decode(payload));
          }
        }
      case 'mls_app':
        final payload = p['payload'] as String?;
        if (payload != null) {
          final inner = await _mlsHandleGroupMessage(base64.decode(payload));
          if (inner != null) {
            final record = decodedPersistRecord;
            if (record != null) {
              unawaited(_persistRecord(_HistoryRecord(
                senderUUID: record.senderUUID,
                messageUUID: record.messageUUID,
                timestamp: record.timestamp,
                nonce: record.nonce,
                plaintext: inner,
              )));
            }
            await _emitDecodedMessage(
              msgId: msgId,
              senderUUIDHex: senderUUIDHex,
              plaintext: inner,
              recvAt: recvAt,
              history: history,
            );
          }
        }
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
          senderPublicKeyHex: senderPub,
          useDisk: shouldCacheToDisk,
          tempPath: tempPath,
        );
      }();
    }
    final pf = await _pendingFiles[fileId]!;
    if (senderPub != null && senderPub.isNotEmpty) {
      pf.senderPublicKeyHex = senderPub;
    }
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

      final effectiveSenderPub = pf.senderPublicKeyHex ?? senderPub;
      final effectiveIsFromMe = _isOwnMessage(sender, effectiveSenderPub);
      _eventController.add(SgtpMessageReceived(
          message: _media(
              fileId, sender, name, mime, type, bytes, history, recvAt,
              senderPub: effectiveSenderPub,
              isFromMe: effectiveIsFromMe,
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
    // Compatibility fallback for older payloads without `pub`.
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
      if (plain.length >= 16) {
        _eventController
            .add(SgtpError(error: 'Message rejected (CK rotation)'));
      }
      await _sendFrame(buildMessageFailedAck(_roomUUID, f.senderUUID, _myUUID));
    } catch (_) {}
  }

  Future<void> _onStatus(ParsedFrame f) async {
    final senderH = uuidBytesToHex(f.senderUUID);
    final peer = _peers[senderH];
    if (peer == null || peer.sharedKey.isEmpty) return;
    if (!await verifyFrame(f.raw, peer.ed25519PubKey)) return;
    try {
      final (nonce, ciphertext) = _sharedKeyCipherParams(f);
      final plain = await decrypt(ciphertext, peer.sharedKey, nonce);
      if (plain.length >= 2) {
        final code = ByteData.view(plain.buffer, plain.offsetInBytes, 2)
            .getUint16(0, Endian.big);
        if (code == SgtpConstants.statusNeedChatKey && _isMaster) {
          await _ensureChatKeyForPeer(senderH);
          return;
        }
        _log.error('Server status {code}', parameters: {'code': code});
        _eventController.add(SgtpError(error: 'Server status $code'));
      }
    } catch (_) {}
  }

  Future<void> _sendNeedChatKeyIfNeeded(String peerHex) async {
    final peer = _peers[peerHex];
    if (peer == null || peer.sharedKey.isEmpty) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final last = _needChatKeyLastSentMsByPeer[peerHex] ?? 0;
    if (now - last < 1500) return;
    _needChatKeyLastSentMsByPeer[peerHex] = now;
    try {
      final plain = Uint8List(2);
      final bd = ByteData.view(plain.buffer);
      bd.setUint16(0, SgtpConstants.statusNeedChatKey, Endian.big);
      final version = peer.protocolVersion;
      final nonce = version >= 0x0002 ? _randomUint64() : now;
      final cipher = await encrypt(plain, peer.sharedKey, nonce);
      final payload = version >= 0x0002
          ? (() {
              final out = Uint8List(8 + cipher.length);
              final outBd = ByteData.view(out.buffer);
              bdSetUint64(outBd, 0, nonce, Endian.big);
              out.setRange(8, 8 + cipher.length, cipher);
              return out;
            })()
          : cipher;
      await _sendFrame(buildStatus(
        _roomUUID,
        peer.uuidBytes,
        _myUUID,
        payload,
        version: version,
      ));
    } catch (e) {
      _log.warning('Failed to send NEED_CHAT_KEY to {peer}: {error}',
          parameters: {'peer': peerHex, 'error': e});
    }
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
    _chatKeyAckEpochByPeer.remove(h);
    _chatKeyRetryCountByPeer.remove(h);
    _chatKeyRetryTimers.remove(h)?.cancel();
    _needChatKeyLastSentMsByPeer.remove(h);
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
    _chatKeyAckEpochByPeer.remove(h);
    _chatKeyRetryCountByPeer.remove(h);
    _chatKeyRetryTimers.remove(h)?.cancel();
    _needChatKeyLastSentMsByPeer.remove(h);
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
    // Sign first — this is CPU/async work, safe to do before entering the queue.
    final Uint8List signed;
    try {
      signed = await signFrame(unsigned, _config.identityKeyPair);
    } catch (e) {
      if (!_eventController.isClosed) {
        _log.error('Failed to sign frame: {error}', parameters: {'error': e});
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
        _log.error('Failed to send frame: {error}', parameters: {'error': e});
        _eventController.add(SgtpError(error: 'Failed to send frame: $e'));
      }
    } finally {
      mine.complete(); // release the next sender
    }
  }

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

  Set<String> _normalizeWhitelist(Set<String> whitelist) {
    return Set.unmodifiable(
      whitelist
          .map((entry) => entry.trim().toLowerCase())
          .where((entry) => entry.isNotEmpty),
    );
  }

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
    for (final timer in _chatKeyRetryTimers.values) {
      timer.cancel();
    }
    _chatKeyRetryTimers.clear();
    _chatKeyRetryCountByPeer.clear();
    _chatKeyAckEpochByPeer.clear();
    _needChatKeyLastSentMsByPeer.clear();
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
    _mls?.close();
    _mls = null;
    _mlsClientReady = false;
    _mlsGroupReady = false;
    _mlsKeyPackageBroadcast = false;
    _mlsGroupCreated = false;
    _mlsInviteInFlight = false;
    _mlsLocalKeyPackageB64 = null;
    _mlsPeerKeyPackages.clear();
    _mlsInvitedPeers.clear();
    _receiveBuffer.clear();
    _sendChain = Future.value(); // reset the send queue
    _lastReceiveAt = DateTime.now();
    try {
      await _transport?.close();
    } catch (_) {}
    _transport = null;
  }

  @override
  Future<void> close() async {
    _sgtpLogCall('close');
    await _cleanup();
    await _eventController.close();
  }
}

/// Deprecated compatibility alias for the previous runtime class name.
@Deprecated(kLegacySgtpClientDeprecationMessage)
class SgtpClient extends OpenMlsChatSession {
  SgtpClient(super.config);
}
