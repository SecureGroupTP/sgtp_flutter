import 'dart:async';
import 'dart:convert' show base64, json, utf8, ascii;
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart' show debugPrint;

import '../core/constants.dart';
import '../core/crypto/chacha20_utils.dart';
import '../core/crypto/ed25519_utils.dart';
import '../core/crypto/x25519_utils.dart';
import '../core/protocol/frame_builder.dart';
import '../core/protocol/frame_parser.dart';
import '../core/protocol/packet_types.dart';
import '../core/uuid_v7.dart';
import '../domain/entities/message.dart';
import '../domain/entities/peer.dart';

// ---------------------------------------------------------------------------
// Internal: pending chunked file reassembly
// ---------------------------------------------------------------------------

class _PendingFile {
  final String fileId;
  final String name;
  final String mime;
  final int totalSize;
  final int totalChunks;
  final String senderUUID;
  final String mediaType; // 'image', 'gif', 'video', 'voice'
  final List<Uint8List?> chunks;

  _PendingFile({
    required this.fileId,
    required this.name,
    required this.mime,
    required this.totalSize,
    required this.totalChunks,
    required this.senderUUID,
    required this.mediaType,
  }) : chunks = List.filled(totalChunks, null);

  bool get isComplete => chunks.every((c) => c != null);

  Uint8List assemble() {
    final buf = BytesBuilder();
    for (final c in chunks) {
      buf.add(c!);
    }
    return buf.takeBytes();
  }
}

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

class SgtpConfig {
  final String serverAddr; // "host:port"
  final Uint8List roomUUID; // 16 bytes, all zeros = create new
  final SimpleKeyPairData identityKeyPair; // Ed25519
  final Uint8List myPublicKey; // 32 bytes Ed25519 pub
  final Set<String> whitelist; // hex strings of trusted ed25519 pub keys

  const SgtpConfig({
    required this.serverAddr,
    required this.roomUUID,
    required this.identityKeyPair,
    required this.myPublicKey,
    required this.whitelist,
  });
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
  SgtpPeerJoined({required this.peerUUID});
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

// ---------------------------------------------------------------------------
// Client state machine states
// ---------------------------------------------------------------------------

enum _ClientState {
  disconnected,
  connecting,
  waitingHandshake,
  ready,
}

// ---------------------------------------------------------------------------
// SgtpClient
// ---------------------------------------------------------------------------

class SgtpClient {
  final SgtpConfig _config;

  // My identity
  final Uint8List _myUUID;
  late final Uint8List _roomUUID;

  // Events stream
  final _eventController = StreamController<SgtpEvent>.broadcast();
  Stream<SgtpEvent> get events => _eventController.stream;

  // TCP socket
  Socket? _socket;
  final List<int> _receiveBuffer = [];

  // State
  _ClientState _state = _ClientState.disconnected;

  // Peers: keyed by hex UUID
  final Map<String, PeerInfo> _peers = {};

  // Ephemeral X25519 key pair (generated fresh for each session)
  SimpleKeyPair? _ephemeralX25519;
  Uint8List? _ephemeralX25519Pub;

  // Chat key
  Uint8List? _chatKey;
  int _chatEpoch = 0;
  int _myNonce = 0;

  // Pending media chunks: file_id → _PendingFile
  final Map<String, _PendingFile> _pendingFiles = {};

  // Master state
  bool _isMaster = false;
  Timer? _ckRotationTimer;

  // INFO delay timer — only started once per session
  bool _infoTimerStarted = false;

  // Set of UUIDs we know about but haven't handshaked yet
  final Set<String> _pendingHandshakes = {};

  // Whether we have sent CHAT_REQUEST
  bool _chatRequestSent = false;

  // Whether we have received CHAT_KEY (ready)
  bool _readyEmitted = false;

  SgtpClient(SgtpConfig config)
      : _config = config,
        _myUUID = generateUUIDv7() {
    final isZero = config.roomUUID.every((b) => b == 0);
    _roomUUID = isZero ? generateUUIDv7() : Uint8List.fromList(config.roomUUID);
  }

  bool get isMaster => _isMaster;
  String get myUUIDHex => uuidBytesToHex(_myUUID);
  String get roomUUIDHex => uuidBytesToHex(_roomUUID);
  List<String> get peerUUIDs => _peers.keys.toList();

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  Future<void> connect() async {
    if (_state != _ClientState.disconnected) return;
    _state = _ClientState.connecting;
    _eventController.add(SgtpConnecting());
    debugPrint('[SGTP] connect() myUUID=$myUUIDHex room=$roomUUIDHex');

    try {
      _ephemeralX25519 = await generateEphemeralKeyPair();
      _ephemeralX25519Pub = await extractPublicKeyBytes(_ephemeralX25519!);

      final parts = _config.serverAddr.split(':');
      final host = parts[0];
      final port = int.parse(parts.last);

      debugPrint('[SGTP] connecting to $host:$port');
      _socket = await Socket.connect(host, port);
      _state = _ClientState.waitingHandshake;
      _eventController.add(SgtpHandshaking());

      _socket!.listen(
        _onData,
        onError: _onSocketError,
        onDone: _onSocketDone,
        cancelOnError: false,
      );

      await _sendFrame(buildIntentFrame(_roomUUID, _myUUID));
      debugPrint('[SGTP] INTENT sent');
    } catch (e) {
      _state = _ClientState.disconnected;
      debugPrint('[SGTP] connect failed: $e');
      _eventController.add(SgtpError(error: 'Connection failed: $e'));
    }
  }

  Future<void> sendMessage(String text) async {
    if (_state != _ClientState.ready || _chatKey == null) return;

    final payload = json.encode({'v': 1, 'type': 'text', 'text': text});
    try {
      final msgUUID = generateUUIDv7();
      final nonce = _myNonce++;
      final plaintext = Uint8List.fromList(utf8.encode(payload));
      final ciphertext = await encrypt(plaintext, _chatKey!, nonce);

      final frame = buildMessage(_roomUUID, _myUUID, msgUUID, nonce, ciphertext);
      await _sendFrame(frame);

      _eventController.add(SgtpMessageReceived(
        message: ChatMessage(
          id: uuidBytesToHex(msgUUID),
          senderUUID: uuidBytesToHex(_myUUID),
          content: text,
          receivedAt: DateTime.now(),
          isFromHistory: false,
          isFromMe: true,
        ),
      ));
    } catch (e) {
      _eventController.add(SgtpError(error: 'Failed to send message: $e'));
    }
  }

  /// Send a media file (image, gif, video, voice) as one or more MESSAGE frames.
  /// Chunks at [SgtpConstants.mediaChunkSize] for large files.
  Future<void> _sendMedia(
    Uint8List bytes,
    String name,
    String mime,
    String mediaType, {
    ChatMessage? echoMessage,
  }) async {
    if (_state != _ClientState.ready || _chatKey == null) return;

    const chunkSize = SgtpConstants.mediaChunkSize;
    final fileId = uuidBytesToHex(generateUUIDv7());
    final totalSize = bytes.length;
    final totalChunks = (totalSize / chunkSize).ceil().clamp(1, 9999);

    try {
      for (int i = 0; i < totalChunks; i++) {
        final start = i * chunkSize;
        final end = (start + chunkSize).clamp(0, totalSize);
        final chunkData = bytes.sublist(start, end);
        final b64 = base64.encode(chunkData);

        final Map<String, dynamic> payload = {
          'v': 1,
          'type': mediaType,
          'file_id': fileId,
          'name': name,
          'mime': mime,
          'size': totalSize,
          'data': b64,
        };
        if (totalChunks > 1) {
          payload['chunk'] = i;
          payload['chunks'] = totalChunks;
        }

        final msgUUID = generateUUIDv7();
        final nonce = _myNonce++;
        final plaintext = Uint8List.fromList(utf8.encode(json.encode(payload)));
        final ciphertext = await encrypt(plaintext, _chatKey!, nonce);
        final frame = buildMessage(_roomUUID, _myUUID, msgUUID, nonce, ciphertext);
        await _sendFrame(frame);
      }

      if (echoMessage != null) {
        _eventController.add(SgtpMessageReceived(message: echoMessage));
      }
    } catch (e) {
      _eventController.add(SgtpError(error: 'Failed to send $mediaType: $e'));
    }
  }

  Future<void> sendImage(Uint8List bytes, String name, String mime) async {
    final isGif = mime == 'image/gif';
    final type = isGif ? 'gif' : 'image';
    final msgType = isGif ? MessageType.gif : MessageType.image;
    await _sendMedia(bytes, name, mime, type,
        echoMessage: ChatMessage(
          id: uuidBytesToHex(generateUUIDv7()),
          senderUUID: uuidBytesToHex(_myUUID),
          content: name,
          imageBytes: bytes,
          mediaMime: mime,
          mediaName: name,
          type: msgType,
          receivedAt: DateTime.now(),
          isFromHistory: false,
          isFromMe: true,
        ));
  }

  Future<void> sendVideo(Uint8List bytes, String name, String mime) async {
    await _sendMedia(bytes, name, mime, 'video',
        echoMessage: ChatMessage(
          id: uuidBytesToHex(generateUUIDv7()),
          senderUUID: uuidBytesToHex(_myUUID),
          content: name,
          videoBytes: bytes,
          mediaMime: mime,
          mediaName: name,
          type: MessageType.video,
          receivedAt: DateTime.now(),
          isFromHistory: false,
          isFromMe: true,
        ));
  }

  Future<void> sendVoice(Uint8List bytes, String mime) async {
    final name = 'voice_${DateTime.now().millisecondsSinceEpoch}.${_mimeToExt(mime)}';
    await _sendMedia(bytes, name, mime, 'voice',
        echoMessage: ChatMessage(
          id: uuidBytesToHex(generateUUIDv7()),
          senderUUID: uuidBytesToHex(_myUUID),
          content: name,
          audioBytes: bytes,
          mediaMime: mime,
          mediaName: name,
          type: MessageType.voice,
          receivedAt: DateTime.now(),
          isFromHistory: false,
          isFromMe: true,
        ));
  }

  String _mimeToExt(String mime) {
    return switch (mime) {
      'audio/m4a' => 'm4a',
      'audio/aac' => 'aac',
      'audio/opus' => 'opus',
      'audio/mpeg' => 'mp3',
      _ => 'audio',
    };
  }

  Future<void> disconnect() async {
    if (_state == _ClientState.disconnected) return;

    try {
      if (_chatKey != null) {
        final nonce = _myNonce++;
        final tag = await encrypt(Uint8List(0), _chatKey!, nonce);
        final frame = buildFin(_roomUUID, _myUUID, nonce, tag.sublist(0, 16));
        await _sendFrame(frame);
      }
    } catch (_) {}

    await _cleanup();
  }

  // ---------------------------------------------------------------------------
  // Internal: socket callbacks
  // ---------------------------------------------------------------------------

  void _onData(List<int> data) {
    _receiveBuffer.addAll(data);
    _processBuffer();
  }

  void _onSocketError(Object error) {
    debugPrint('[SGTP] socket error: $error');
    _eventController.add(SgtpError(error: 'Socket error: $error'));
    _cleanup();
  }

  void _onSocketDone() {
    debugPrint('[SGTP] socket closed');
    if (_state != _ClientState.disconnected) {
      _cleanup();
      _eventController.add(SgtpDisconnected());
    }
  }

  void _processBuffer() {
    while (true) {
      final result = tryExtractFrame(_receiveBuffer);
      if (result == null) break;
      _receiveBuffer.removeRange(0, result.bytesConsumed);
      _handleFrame(result.frame);
    }
  }

  // ---------------------------------------------------------------------------
  // Internal: frame dispatch
  // ---------------------------------------------------------------------------

  void _handleFrame(ParsedFrame frame) async {
    try {
      await _dispatchFrame(frame);
    } catch (e) {
      debugPrint('[SGTP] frame handling error: $e');
    }
  }

  /// BUG FIX: validate timestamp per spec §1 TIMESTAMP_WINDOW = 30 000ms
  bool _validateTimestamp(int timestamp) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final diff = (now - timestamp).abs();
    if (diff > SgtpConstants.timestampWindow) {
      debugPrint('[SGTP] timestamp rejected: diff=${diff}ms > ${SgtpConstants.timestampWindow}ms');
      return false;
    }
    return true;
  }

  Future<void> _dispatchFrame(ParsedFrame frame) async {
    // BUG FIX: validate timestamp before processing any frame
    if (!_validateTimestamp(frame.timestamp)) {
      return;
    }

    final pktHex = frame.packetType.toRadixString(16).padLeft(4, '0');
    debugPrint('[SGTP] RX pkt=0x$pktHex from=${uuidBytesToHex(frame.senderUUID)}');

    switch (frame.packetType) {
      case PacketType.intent:
        await _handleIntent(frame);
      case PacketType.ping:
        await _handlePing(frame);
      case PacketType.pong:
        await _handlePong(frame);
      case PacketType.info:
        if (frame.payloadLength == 0) {
          await _handleInfoRequest(frame);
        } else {
          await _handleInfoResponse(frame);
        }
      case PacketType.chatRequest:
        if (_isMaster) await _handleChatRequest(frame);
      case PacketType.chatKey:
        await _handleChatKey(frame);
      case PacketType.chatKeyAck:
        // Master tracks ACKs — for now we just log
        debugPrint('[SGTP] CHAT_KEY_ACK from ${uuidBytesToHex(frame.senderUUID)}');
      case PacketType.message:
        await _handleMessage(frame);
      case PacketType.messageFailed:
        await _handleMessageFailed(frame);
      case PacketType.status:
        await _handleStatus(frame);
      case PacketType.fin:
        await _handleFin(frame);
      case PacketType.kicked:
        _handleKicked(frame);
      // History packets — not yet implemented but don't crash
      case PacketType.hsir:
      case PacketType.hsi:
      case PacketType.hsr:
      case PacketType.hsra:
        debugPrint('[SGTP] history packet 0x$pktHex — not handled yet');
      default:
        debugPrint('[SGTP] unknown packet type 0x$pktHex');
    }
  }

  // ---------------------------------------------------------------------------
  // Internal: protocol handlers
  // ---------------------------------------------------------------------------

  Future<void> _handleIntent(ParsedFrame frame) async {
    final senderHex = uuidBytesToHex(frame.senderUUID);
    if (senderHex == myUUIDHex) return;
    debugPrint('[SGTP] INTENT from $senderHex → sending PING');
    await _sendPing(frame.senderUUID);
  }

  Future<void> _handlePing(ParsedFrame frame) async {
    final senderHex = uuidBytesToHex(frame.senderUUID);
    if (senderHex == myUUIDHex) return;

    // BUG FIX: minimum payload is 64 (two 32-byte keys), "Client Hello" body optional
    if (frame.payloadLength < SgtpConstants.pingPayloadMinLength) {
      debugPrint('[SGTP] PING payload too short (${frame.payloadLength}), dropping');
      return;
    }

    final ed25519Pub = frame.ed25519PubKey;
    final ed25519Hex = _bytesToHex(ed25519Pub);
    if (!_config.whitelist.contains(ed25519Hex)) {
      debugPrint('[SGTP] PING from unlisted peer → dropping');
      return;
    }

    if (!await verifyFrame(frame.raw, ed25519Pub)) {
      debugPrint('[SGTP] PING signature invalid → dropping');
      return;
    }

    // BUG FIX: verify "Client Hello" body per spec §3
    if (frame.payloadLength >= SgtpConstants.pingPayloadLength) {
      final body = ascii.decode(frame.payload.sublist(64, 76), allowInvalid: true);
      if (body != SgtpConstants.clientHello) {
        debugPrint('[SGTP] PING body mismatch: "$body", dropping');
        return;
      }
    }

    final sharedSecret = await computeSharedSecret(_ephemeralX25519!, frame.x25519PubKey);

    final existingPeer = _peers[senderHex];
    _peers[senderHex] = PeerInfo(
      uuid: senderHex,
      uuidBytes: Uint8List.fromList(frame.senderUUID),
      ed25519PubKey: ed25519Pub,
      sharedKey: sharedSecret,
      handshakeComplete: existingPeer?.handshakeComplete ?? false,
    );

    // Send PONG after computing shared secret
    await _sendPong(frame.senderUUID);

    // BUG FIX: schedule INFO after PING (per spec §3: after first PING/PONG)
    _scheduleInfoIfNeeded();

    if (!_eventController.isClosed) {
      _eventController.add(SgtpPeerJoined(peerUUID: senderHex));
    }
  }

  Future<void> _handlePong(ParsedFrame frame) async {
    final senderHex = uuidBytesToHex(frame.senderUUID);
    if (senderHex == myUUIDHex) return;

    if (frame.payloadLength < SgtpConstants.pingPayloadMinLength) {
      debugPrint('[SGTP] PONG payload too short, dropping');
      return;
    }

    final ed25519Pub = frame.ed25519PubKey;
    final ed25519Hex = _bytesToHex(ed25519Pub);
    if (!_config.whitelist.contains(ed25519Hex)) {
      debugPrint('[SGTP] PONG from unlisted peer → dropping');
      return;
    }

    if (!await verifyFrame(frame.raw, ed25519Pub)) {
      debugPrint('[SGTP] PONG signature invalid → dropping');
      return;
    }

    // BUG FIX: verify "Client Hello" body
    if (frame.payloadLength >= SgtpConstants.pingPayloadLength) {
      final body = ascii.decode(frame.payload.sublist(64, 76), allowInvalid: true);
      if (body != SgtpConstants.clientHello) {
        debugPrint('[SGTP] PONG body mismatch: "$body", dropping');
        return;
      }
    }

    final sharedSecret = await computeSharedSecret(_ephemeralX25519!, frame.x25519PubKey);

    final existingPeer = _peers[senderHex];
    _peers[senderHex] = PeerInfo(
      uuid: senderHex,
      uuidBytes: Uint8List.fromList(frame.senderUUID),
      ed25519PubKey: ed25519Pub,
      sharedKey: sharedSecret,
      handshakeComplete: true,
    );

    _pendingHandshakes.remove(senderHex);
    debugPrint('[SGTP] PONG: peer $senderHex handshakeComplete=true');

    if (!_eventController.isClosed && existingPeer?.handshakeComplete != true) {
      _eventController.add(SgtpPeerJoined(peerUUID: senderHex));
    }

    // BUG FIX: also schedule INFO after PONG (per Go reference impl)
    _scheduleInfoIfNeeded();

    await _checkAndSendChatRequest();
  }

  /// BUG FIX: schedule the 1s INFO-request timer.
  /// Per spec §3 and Go reference: called after first PING *or* PONG.
  /// If we are already master (smallest UUID), skip INFO and just update state.
  void _scheduleInfoIfNeeded() {
    if (_infoTimerStarted) return;
    _infoTimerStarted = true;
    debugPrint('[SGTP] scheduling INFO request in ${SgtpConstants.infoDelayMs}ms');

    Future.delayed(Duration(milliseconds: SgtpConstants.infoDelayMs), () async {
      if (_state == _ClientState.disconnected) return;

      // BUG FIX: if we are master, no INFO needed — just update master status
      _updateMasterStatus();
      if (_isMaster) {
        debugPrint('[SGTP] INFO timer: we are master, no INFO needed');
        // Master is ready as soon as it has any peers
        await _checkAndSendChatRequest();
        return;
      }

      debugPrint('[SGTP] INFO timer fired → sending INFO request');
      await _sendInfoRequest();
    });
  }

  Future<void> _sendInfoRequest() async {
    final master = _getMasterPeerUUID();
    if (master == null) {
      // No peers known yet — skip (we might be master)
      debugPrint('[SGTP] _sendInfoRequest: no peers or we are master');
      return;
    }
    debugPrint('[SGTP] sending INFO request to ${uuidBytesToHex(master)}');
    final frame = buildInfoRequest(_roomUUID, master, _myUUID);
    await _sendFrame(frame);
  }

  Future<void> _handleInfoRequest(ParsedFrame frame) async {
    final senderHex = uuidBytesToHex(frame.senderUUID);
    final peerUUIDs = _peers.values.map((p) => p.uuidBytes).toList();
    peerUUIDs.add(_myUUID);
    debugPrint('[SGTP] INFO request from $senderHex → responding with ${peerUUIDs.length} UUIDs');
    final responseFrame = buildInfoResponse(_roomUUID, frame.senderUUID, _myUUID, peerUUIDs);
    await _sendFrame(responseFrame);
  }

  Future<void> _handleInfoResponse(ParsedFrame frame) async {
    final uuids = frame.infoUUIDs;
    final myHex = myUUIDHex;
    debugPrint('[SGTP] INFO response: ${uuids.length} UUIDs received');

    bool pingedAny = false;
    for (final uuid in uuids) {
      final uuidHex = uuidBytesToHex(uuid);
      if (uuidHex == myHex) continue;
      if (_peers.containsKey(uuidHex)) continue;

      debugPrint('[SGTP] INFO response: unknown peer $uuidHex → PING');
      _pendingHandshakes.add(uuidHex);
      await _sendPing(uuid);
      pingedAny = true;
    }

    if (!pingedAny) {
      await _checkAndSendChatRequest();
    }
  }

  Future<void> _checkAndSendChatRequest() async {
    if (_chatRequestSent) return;
    if (_pendingHandshakes.isNotEmpty) return;
    if (_peers.isEmpty) return;

    final allReady = _peers.values.every((p) => p.sharedKey.isNotEmpty);
    if (!allReady) return;

    _updateMasterStatus();
    debugPrint('[SGTP] _checkAndSendChatRequest: isMaster=$_isMaster peers=${_peers.length}');

    if (!_isMaster) {
      // BUG FIX: non-master waits for CHAT_KEY from master after sending CHAT_REQUEST
      // Per spec §4.1: new client sends CHAT_REQUEST; master then issues CHAT_KEY
      final masterUUID = _getMasterPeerUUID();
      if (masterUUID == null) return;
      final knownUUIDs = _peers.values.map((p) => p.uuidBytes).toList();
      debugPrint('[SGTP] sending CHAT_REQUEST to master ${uuidBytesToHex(masterUUID)}');
      final frame = buildChatRequest(_roomUUID, masterUUID, _myUUID, knownUUIDs);
      await _sendFrame(frame);
      _chatRequestSent = true;
    } else {
      // BUG FIX: master issues CK immediately when it has all peers handshaked.
      // Master path: if we're already master and have peers (e.g. first client alone
      // or master after rotation), issue CK without waiting for CHAT_REQUEST.
      _chatRequestSent = true;
      debugPrint('[SGTP] master: issuing CHAT_KEY to all peers');
      await _issueChatKeyToAll();
    }
  }

  Future<void> _handleChatRequest(ParsedFrame frame) async {
    if (!_isMaster) return;
    final senderHex = uuidBytesToHex(frame.senderUUID);
    debugPrint('[SGTP] CHAT_REQUEST from $senderHex → issuing new CK');
    // Per spec §4.1: master verifies all participants trust the new client,
    // then generates new CK and distributes to everyone.
    await _issueChatKeyToAll();
  }

  Future<void> _issueChatKeyToAll() async {
    if (_peers.isEmpty) {
      debugPrint('[SGTP] _issueChatKeyToAll: no peers, skipping');
      return;
    }

    final rng = Random.secure();
    final newKey = Uint8List.fromList(List.generate(32, (_) => rng.nextInt(256)));

    _chatKey = newKey;
    // BUG FIX: epoch must be strictly monotonically increasing. Use timestamp-based
    // counter, but ensure it's always > previous epoch.
    final tsEpoch = DateTime.now().millisecondsSinceEpoch;
    _chatEpoch = tsEpoch > _chatEpoch ? tsEpoch : _chatEpoch + 1;
    _myNonce = 0;
    debugPrint('[SGTP] issuing new CHAT_KEY epoch=$_chatEpoch to ${_peers.length} peers');

    for (final peer in _peers.values) {
      if (peer.sharedKey.isEmpty) continue;
      try {
        final encryptedKey = await encrypt(newKey, peer.sharedKey, _chatEpoch);
        final frame = buildChatKey(_roomUUID, peer.uuidBytes, _myUUID, _chatEpoch, encryptedKey);
        await _sendFrame(frame);
        debugPrint('[SGTP] CHAT_KEY sent to ${peer.uuid}');
      } catch (e) {
        debugPrint('[SGTP] failed to send CHAT_KEY to ${peer.uuid}: $e');
      }
    }

    if (!_readyEmitted) {
      _readyEmitted = true;
      _state = _ClientState.ready;
      _eventController.add(SgtpReady(isMaster: true, roomUUIDHex: roomUUIDHex));
    }

    _ckRotationTimer?.cancel();
    _ckRotationTimer = Timer(
        const Duration(seconds: SgtpConstants.ckRotationInterval), _rotateChatKey);
  }

  Future<void> _rotateChatKey() async {
    if (_state == _ClientState.ready && _isMaster) {
      debugPrint('[SGTP] rotating CK (periodic)');
      await _issueChatKeyToAll();
    }
  }

  Future<void> _handleChatKey(ParsedFrame frame) async {
    if (frame.payloadLength < SgtpConstants.chatKeyPayloadLength) {
      debugPrint('[SGTP] CHAT_KEY payload too short, dropping');
      return;
    }

    final epoch = frame.epoch;
    final encryptedKey = frame.encryptedChatKey;
    final senderHex = uuidBytesToHex(frame.senderUUID);
    final peer = _peers[senderHex];

    if (peer == null || peer.sharedKey.isEmpty) {
      debugPrint('[SGTP] CHAT_KEY from unknown peer $senderHex, dropping');
      return;
    }

    try {
      final decryptedKey = await decrypt(encryptedKey, peer.sharedKey, epoch);
      if (decryptedKey.length != 32) {
        debugPrint('[SGTP] CHAT_KEY bad decrypted length ${decryptedKey.length}');
        return;
      }

      _chatKey = Uint8List.fromList(decryptedKey);
      _chatEpoch = epoch;
      _myNonce = 0;
      debugPrint('[SGTP] CHAT_KEY applied epoch=$epoch');

      final ackFrame = buildChatKeyAck(_roomUUID, frame.senderUUID, _myUUID);
      await _sendFrame(ackFrame);

      if (!_readyEmitted) {
        _readyEmitted = true;
        _state = _ClientState.ready;
        _eventController.add(SgtpReady(isMaster: false, roomUUIDHex: roomUUIDHex));
      }
    } catch (e) {
      debugPrint('[SGTP] CHAT_KEY decryption failed: $e');
      _eventController.add(SgtpError(error: 'Failed to decrypt CHAT_KEY: $e'));
    }
  }

  Future<void> _handleMessage(ParsedFrame frame) async {
    if (_chatKey == null) return;
    if (frame.payloadLength < 24 + 16) return;

    final senderHex = uuidBytesToHex(frame.senderUUID);
    if (senderHex == myUUIDHex) return; // ignore own echo from server

    try {
      final nonce = frame.messageNonce;
      final ciphertext = frame.messageCiphertext;
      final plaintext = await decrypt(ciphertext, _chatKey!, nonce);
      final raw = utf8.decode(plaintext);
      final msgUUID = uuidBytesToHex(frame.messageUUID);

      Map<String, dynamic>? payload;
      try {
        payload = json.decode(raw) as Map<String, dynamic>;
      } catch (_) {}

      if (payload == null || payload['v'] != 1) {
        _eventController.add(SgtpMessageReceived(
          message: ChatMessage(
            id: msgUUID,
            senderUUID: senderHex,
            content: raw,
            receivedAt: DateTime.now(),
            isFromHistory: false,
            isFromMe: false,
          ),
        ));
        return;
      }

      final type = payload['type'] as String?;

      switch (type) {
        case 'text':
          _eventController.add(SgtpMessageReceived(
            message: ChatMessage(
              id: msgUUID,
              senderUUID: senderHex,
              content: (payload['text'] as String?) ?? '',
              receivedAt: DateTime.now(),
              isFromHistory: false,
              isFromMe: false,
            ),
          ));
        case 'image':
          await _handleMediaPayload(msgUUID, senderHex, payload, 'image');
        case 'gif':
          await _handleMediaPayload(msgUUID, senderHex, payload, 'gif');
        case 'video':
          await _handleMediaPayload(msgUUID, senderHex, payload, 'video');
        case 'voice':
          await _handleMediaPayload(msgUUID, senderHex, payload, 'voice');
        default:
          debugPrint('[SGTP] unknown message type: $type');
      }
    } catch (e) {
      // Decryption failed - possibly old epoch, silently drop
      debugPrint('[SGTP] MESSAGE decrypt failed: $e');
    }
  }

  Future<void> _handleMediaPayload(
    String msgUUID,
    String senderHex,
    Map<String, dynamic> payload,
    String mediaType,
  ) async {
    final fileId = payload['file_id'] as String? ?? msgUUID;
    final name = payload['name'] as String? ?? 'file';
    final mime = payload['mime'] as String? ?? 'application/octet-stream';
    final totalSize = (payload['size'] as num?)?.toInt() ?? 0;
    final dataB64 = payload['data'] as String? ?? '';
    final chunkBytes = base64.decode(dataB64);

    // Single-frame message
    if (!payload.containsKey('chunk')) {
      _eventController.add(SgtpMessageReceived(
        message: _buildMediaMessage(msgUUID, senderHex, name, mime, mediaType, chunkBytes),
      ));
      return;
    }

    // Chunked
    final chunkIndex = (payload['chunk'] as num).toInt();
    final totalChunks = (payload['chunks'] as num).toInt();

    _pendingFiles.putIfAbsent(
      fileId,
      () => _PendingFile(
        fileId: fileId,
        name: name,
        mime: mime,
        totalSize: totalSize,
        totalChunks: totalChunks,
        senderUUID: senderHex,
        mediaType: mediaType,
      ),
    );

    final pf = _pendingFiles[fileId]!;
    if (chunkIndex < pf.chunks.length) {
      pf.chunks[chunkIndex] = chunkBytes;
    }

    if (pf.isComplete) {
      _pendingFiles.remove(fileId);
      final assembled = pf.assemble();
      _eventController.add(SgtpMessageReceived(
        message: _buildMediaMessage(fileId, senderHex, name, mime, mediaType, assembled),
      ));
    }
  }

  ChatMessage _buildMediaMessage(
    String id,
    String senderHex,
    String name,
    String mime,
    String mediaType,
    Uint8List bytes,
  ) {
    switch (mediaType) {
      case 'gif':
        return ChatMessage(
          id: id,
          senderUUID: senderHex,
          content: name,
          imageBytes: bytes,
          mediaMime: mime,
          mediaName: name,
          type: MessageType.gif,
          receivedAt: DateTime.now(),
          isFromHistory: false,
          isFromMe: false,
        );
      case 'video':
        return ChatMessage(
          id: id,
          senderUUID: senderHex,
          content: name,
          videoBytes: bytes,
          mediaMime: mime,
          mediaName: name,
          type: MessageType.video,
          receivedAt: DateTime.now(),
          isFromHistory: false,
          isFromMe: false,
        );
      case 'voice':
        return ChatMessage(
          id: id,
          senderUUID: senderHex,
          content: name,
          audioBytes: bytes,
          mediaMime: mime,
          mediaName: name,
          type: MessageType.voice,
          receivedAt: DateTime.now(),
          isFromHistory: false,
          isFromMe: false,
        );
      default: // 'image'
        return ChatMessage(
          id: id,
          senderUUID: senderHex,
          content: name,
          imageBytes: bytes,
          mediaMime: mime,
          mediaName: name,
          type: MessageType.image,
          receivedAt: DateTime.now(),
          isFromHistory: false,
          isFromMe: false,
        );
    }
  }

  /// BUG FIX: handle MESSAGE_FAILED per spec §4.3
  Future<void> _handleMessageFailed(ParsedFrame frame) async {
    final senderHex = uuidBytesToHex(frame.senderUUID);
    final peer = _peers[senderHex];
    if (peer == null || peer.sharedKey.isEmpty) return;

    try {
      // MESSAGE_FAILED payload is encrypted with shared key; nonce = timestamp
      final nonce = frame.timestamp;
      final plaintext = await decrypt(frame.payload, peer.sharedKey, nonce);
      if (plaintext.length >= 16) {
        final failedMsgUUID = _bytesToHex(plaintext.sublist(0, 16));
        debugPrint('[SGTP] MESSAGE_FAILED: msgUUID=$failedMsgUUID (CK rotation)');
        _eventController.add(SgtpError(error: 'Message rejected (CK rotation): $failedMsgUUID'));
      }

      // Send MESSAGE_FAILED_ACK
      final ackFrame = buildMessageFailedAck(_roomUUID, frame.senderUUID, _myUUID);
      await _sendFrame(ackFrame);
    } catch (e) {
      debugPrint('[SGTP] MESSAGE_FAILED handling error: $e');
    }
  }

  /// BUG FIX: handle STATUS per spec §0x0A
  Future<void> _handleStatus(ParsedFrame frame) async {
    final senderHex = uuidBytesToHex(frame.senderUUID);
    final peer = _peers[senderHex];
    if (peer == null || peer.sharedKey.isEmpty) {
      debugPrint('[SGTP] STATUS from unknown peer $senderHex');
      return;
    }

    try {
      final nonce = frame.timestamp;
      final plaintext = await decrypt(frame.payload, peer.sharedKey, nonce);
      if (plaintext.length >= 2) {
        final bd = ByteData.view(plaintext.buffer, plaintext.offsetInBytes, 2);
        final code = bd.getUint16(0, Endian.big);
        final msg = plaintext.length > 2 ? utf8.decode(plaintext.sublist(2)) : '';
        debugPrint('[SGTP] STATUS code=$code msg="$msg"');
        _eventController.add(SgtpError(error: 'Server status $code: $msg'));
      }
    } catch (e) {
      debugPrint('[SGTP] STATUS handling error: $e');
    }
  }

  /// BUG FIX: FIN handling — verify Poly1305 tag and rotate CK if master (§7.1)
  Future<void> _handleFin(ParsedFrame frame) async {
    final senderHex = uuidBytesToHex(frame.senderUUID);
    if (senderHex == myUUIDHex) return;

    // BUG FIX: verify FIN authenticity using current CK (spec §7.1)
    if (_chatKey != null && frame.payloadLength >= SgtpConstants.finPayloadLength) {
      try {
        final tag = frame.finTag; // 16-byte poly1305 tag of empty plaintext
        await decrypt(tag, _chatKey!, frame.finNonce);
        // If decrypt succeeds, FIN is authentic
      } catch (e) {
        debugPrint('[SGTP] FIN authentication failed from $senderHex: $e');
        return; // reject unauthenticated FIN
      }
    }

    _peers.remove(senderHex);
    _pendingHandshakes.remove(senderHex);
    _eventController.add(SgtpPeerLeft(peerUUID: senderHex));
    debugPrint('[SGTP] FIN from $senderHex — peer removed');

    // BUG FIX: master must rotate CK after FIN so departed peer can't read future msgs
    if (_isMaster && _state == _ClientState.ready && _peers.isNotEmpty) {
      debugPrint('[SGTP] FIN: rotating CK for remaining peers');
      await _issueChatKeyToAll();
    }
  }

  void _handleKicked(ParsedFrame frame) {
    if (frame.payloadLength < 16) return;
    final targetUUID = uuidBytesToHex(frame.payload.sublist(0, 16));
    _peers.remove(targetUUID);
    _pendingHandshakes.remove(targetUUID);
    _eventController.add(SgtpPeerLeft(peerUUID: targetUUID));
    debugPrint('[SGTP] KICKED: $targetUUID removed');
  }

  // ---------------------------------------------------------------------------
  // Internal: helpers
  // ---------------------------------------------------------------------------

  Future<void> _sendPing(Uint8List receiverUUID) async {
    if (_ephemeralX25519Pub == null) return;
    final frame = buildPingFrame(
      _roomUUID, receiverUUID, _myUUID,
      _ephemeralX25519Pub!, _config.myPublicKey,
    );
    await _sendFrame(frame);
  }

  Future<void> _sendPong(Uint8List receiverUUID) async {
    if (_ephemeralX25519Pub == null) return;
    final frame = buildPongFrame(
      _roomUUID, receiverUUID, _myUUID,
      _ephemeralX25519Pub!, _config.myPublicKey,
    );
    await _sendFrame(frame);
  }

  Future<void> _sendFrame(Uint8List unsignedFrame) async {
    try {
      final signed = await signFrame(unsignedFrame, _config.identityKeyPair);
      _socket?.add(signed);
    } catch (e) {
      debugPrint('[SGTP] failed to send frame: $e');
      _eventController.add(SgtpError(error: 'Failed to send frame: $e'));
    }
  }

  void _updateMasterStatus() {
    _isMaster = true;
    for (final peer in _peers.values) {
      if (compareBytes(peer.uuidBytes, _myUUID) < 0) {
        _isMaster = false;
        break;
      }
    }
  }

  /// Returns the UUID bytes of the PEER (not self) with the smallest UUID.
  /// BUG FIX: renamed from _getMasterUUID to clarify it returns a PEER uuid,
  /// never our own UUID (to avoid sending INFO requests to ourselves).
  Uint8List? _getMasterPeerUUID() {
    if (_peers.isEmpty) return null;

    Uint8List? smallest;
    for (final peer in _peers.values) {
      if (smallest == null || compareBytes(peer.uuidBytes, smallest) < 0) {
        smallest = peer.uuidBytes;
      }
    }

    // If our UUID is smaller than the smallest peer, WE are master → return null
    if (smallest != null && compareBytes(_myUUID, smallest) < 0) {
      return null; // we are master, don't send INFO to ourselves
    }

    return smallest;
  }

  String _bytesToHex(Uint8List b) =>
      b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

  Future<void> _cleanup() async {
    _state = _ClientState.disconnected;
    _ckRotationTimer?.cancel();
    _ckRotationTimer = null;
    _infoTimerStarted = false;
    _chatRequestSent = false;
    _readyEmitted = false;
    // BUG FIX: reset _isMaster on cleanup so reconnect works correctly
    _isMaster = false;
    _peers.clear();
    _pendingHandshakes.clear();
    _pendingFiles.clear();
    _chatKey = null;
    _chatEpoch = 0;
    _myNonce = 0;
    _receiveBuffer.clear();

    try {
      await _socket?.close();
    } catch (_) {}
    _socket = null;
  }

  Future<void> close() async {
    await _cleanup();
    await _eventController.close();
  }
}
