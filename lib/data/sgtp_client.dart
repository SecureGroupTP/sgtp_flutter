import 'dart:async';
import 'dart:convert' show base64, json, utf8;
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
  final List<Uint8List?> chunks;

  _PendingFile({
    required this.fileId,
    required this.name,
    required this.mime,
    required this.totalSize,
    required this.totalChunks,
    required this.senderUUID,
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

  // Pending image chunks: file_id → _PendingFile
  final Map<String, _PendingFile> _pendingFiles = {};

  // Master state
  bool _isMaster = false;
  Timer? _ckRotationTimer;

  // INFO delay timer
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
    // Resolve room UUID
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
      // Generate ephemeral X25519 key pair
      _ephemeralX25519 = await generateEphemeralKeyPair();
      _ephemeralX25519Pub = await extractPublicKeyBytes(_ephemeralX25519!);
      final pubHex = _ephemeralX25519Pub!.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      debugPrint('[SGTP] ephemeral X25519 pub=$pubHex');

      // Parse host:port
      final parts = _config.serverAddr.split(':');
      final host = parts[0];
      final port = int.parse(parts.last);

      debugPrint('[SGTP] connecting to $host:$port');
      _socket = await Socket.connect(host, port);
      _state = _ClientState.waitingHandshake;
      _eventController.add(SgtpHandshaking());
      debugPrint('[SGTP] TCP connected, sending INTENT');

      // Listen for data
      _socket!.listen(
        _onData,
        onError: _onSocketError,
        onDone: _onSocketDone,
        cancelOnError: false,
      );

      // Send intent frame
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

  /// Send an image as one or more MESSAGE frames.
  /// Files ≤ 10 MiB are sent in a single frame; larger files are chunked at 8 MiB.
  Future<void> sendImage(Uint8List bytes, String name, String mime) async {
    if (_state != _ClientState.ready || _chatKey == null) return;

    const chunkSize = 8 * 1024 * 1024; // 8 MiB raw
    final fileId = uuidBytesToHex(generateUUIDv7());
    final totalSize = bytes.length;
    final chunks = (totalSize / chunkSize).ceil();

    try {
      for (int i = 0; i < chunks; i++) {
        final start = i * chunkSize;
        final end = (start + chunkSize).clamp(0, totalSize);
        final chunkData = bytes.sublist(start, end);
        final b64 = base64.encode(chunkData);

        final Map<String, dynamic> payload = {
          'v': 1,
          'type': 'image',
          'file_id': fileId,
          'name': name,
          'mime': mime,
          'size': totalSize,
          'data': b64,
        };
        if (chunks > 1) {
          payload['chunk'] = i;
          payload['chunks'] = chunks;
        }

        final msgUUID = generateUUIDv7();
        final nonce = _myNonce++;
        final plaintext = Uint8List.fromList(utf8.encode(json.encode(payload)));
        final ciphertext = await encrypt(plaintext, _chatKey!, nonce);
        final frame = buildMessage(_roomUUID, _myUUID, msgUUID, nonce, ciphertext);
        await _sendFrame(frame);
      }

      // Echo the full image locally immediately
      final echoId = uuidBytesToHex(generateUUIDv7());
      _eventController.add(SgtpMessageReceived(
        message: ChatMessage(
          id: echoId,
          senderUUID: uuidBytesToHex(_myUUID),
          content: name,
          imageBytes: bytes,
          type: MessageType.image,
          receivedAt: DateTime.now(),
          isFromHistory: false,
          isFromMe: true,
        ),
      ));
    } catch (e) {
      _eventController.add(SgtpError(error: 'Failed to send image: $e'));
    }
  }

  Future<void> disconnect() async {
    if (_state == _ClientState.disconnected) return;

    try {
      if (_chatKey != null) {
        final nonce = _myNonce++;
        // Encrypt empty plaintext for FIN tag
        final tag = await encrypt(Uint8List(0), _chatKey!, nonce);
        final frame = buildFin(_roomUUID, _myUUID, nonce, tag.sublist(0, 16));
        await _sendFrame(frame);
      }
    } catch (_) {
      // best effort
    }

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
      _eventController.add(SgtpError(error: 'Frame handling error: $e'));
    }
  }

  Future<void> _dispatchFrame(ParsedFrame frame) async {
    final pktHex = frame.packetType.toRadixString(16).padLeft(4, '0');
    debugPrint('[SGTP] RX pkt=0x$pktHex from=${uuidBytesToHex(frame.senderUUID)} payloadLen=${frame.payloadLength}');
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
        if (_isMaster) {
          await _handleChatRequest(frame);
        }
      case PacketType.chatKey:
        await _handleChatKey(frame);
      case PacketType.chatKeyAck:
        break;
      case PacketType.message:
        await _handleMessage(frame);
      case PacketType.fin:
        _handleFin(frame);
      default:
        break;
    }
  }

  // ---------------------------------------------------------------------------
  // Internal: protocol handlers
  // ---------------------------------------------------------------------------

  Future<void> _handleIntent(ParsedFrame frame) async {
    final senderHex = uuidBytesToHex(frame.senderUUID);
    if (senderHex == uuidBytesToHex(_myUUID)) {
      debugPrint('[SGTP] INTENT from self, ignoring');
      return;
    }
    debugPrint('[SGTP] INTENT from $senderHex → sending PING');
    await _sendPing(frame.senderUUID);
  }

  Future<void> _handlePing(ParsedFrame frame) async {
    final senderHex = uuidBytesToHex(frame.senderUUID);
    if (senderHex == uuidBytesToHex(_myUUID)) {
      debugPrint('[SGTP] PING from self, ignoring');
      return;
    }
    debugPrint('[SGTP] PING from $senderHex payloadLen=${frame.payloadLength}');

    if (frame.payloadLength < 76) {
      debugPrint('[SGTP] PING payload too short (${frame.payloadLength} < 76), dropping');
      return;
    }

    final ed25519Pub = frame.ed25519PubKey;
    final ed25519Hex = ed25519Pub.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    final inWhitelist = _config.whitelist.contains(ed25519Hex);
    debugPrint('[SGTP] PING ed25519=${ed25519Hex.substring(0, 16)}... whitelistSize=${_config.whitelist.length} inWhitelist=$inWhitelist');

    if (!inWhitelist) {
      debugPrint('[SGTP] PING ed25519 NOT in whitelist → dropping');
      return;
    }

    final valid = await verifyFrame(frame.raw, ed25519Pub);
    debugPrint('[SGTP] PING sig valid=$valid');
    if (!valid) {
      debugPrint('[SGTP] PING signature invalid → dropping');
      return;
    }

    debugPrint('[SGTP] PING ok → sending PONG to $senderHex');
    await _sendPong(frame.senderUUID);

    final theirX25519Pub = frame.x25519PubKey;
    final sharedSecret = await computeSharedSecret(_ephemeralX25519!, theirX25519Pub);
    debugPrint('[SGTP] PING shared secret computed');

    final existingPeer = _peers[senderHex];
    _peers[senderHex] = PeerInfo(
      uuid: senderHex,
      uuidBytes: Uint8List.fromList(frame.senderUUID),
      ed25519PubKey: ed25519Pub,
      sharedKey: sharedSecret,
      handshakeComplete: existingPeer?.handshakeComplete ?? false,
    );

    if (!_infoTimerStarted) {
      _infoTimerStarted = true;
      debugPrint('[SGTP] starting INFO timer (${SgtpConstants.infoDelayMs}ms)');
      Future.delayed(const Duration(milliseconds: SgtpConstants.infoDelayMs), () {
        if (_state != _ClientState.disconnected) {
          debugPrint('[SGTP] INFO timer fired → sending INFO request');
          _sendInfoRequest();
        }
      });
    }

    if (!_eventController.isClosed) {
      _eventController.add(SgtpPeerJoined(peerUUID: senderHex));
    }
  }

  Future<void> _handlePong(ParsedFrame frame) async {
    final senderHex = uuidBytesToHex(frame.senderUUID);
    if (senderHex == uuidBytesToHex(_myUUID)) {
      debugPrint('[SGTP] PONG from self, ignoring');
      return;
    }
    debugPrint('[SGTP] PONG from $senderHex payloadLen=${frame.payloadLength}');

    if (frame.payloadLength < 76) {
      debugPrint('[SGTP] PONG payload too short (${frame.payloadLength} < 76), dropping');
      return;
    }

    final ed25519Pub = frame.ed25519PubKey;
    final ed25519Hex = ed25519Pub.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    final inWhitelist = _config.whitelist.contains(ed25519Hex);
    debugPrint('[SGTP] PONG ed25519=${ed25519Hex.substring(0, 16)}... inWhitelist=$inWhitelist');

    if (!inWhitelist) {
      debugPrint('[SGTP] PONG ed25519 NOT in whitelist → dropping');
      return;
    }

    final valid = await verifyFrame(frame.raw, ed25519Pub);
    debugPrint('[SGTP] PONG sig valid=$valid');
    if (!valid) {
      debugPrint('[SGTP] PONG signature invalid → dropping');
      return;
    }

    final theirX25519Pub = frame.x25519PubKey;
    final sharedSecret = await computeSharedSecret(_ephemeralX25519!, theirX25519Pub);
    debugPrint('[SGTP] PONG shared secret computed');

    final existingPeer = _peers[senderHex];
    _peers[senderHex] = PeerInfo(
      uuid: senderHex,
      uuidBytes: Uint8List.fromList(frame.senderUUID),
      ed25519PubKey: ed25519Pub,
      sharedKey: sharedSecret,
      handshakeComplete: true,
    );

    _pendingHandshakes.remove(senderHex);
    debugPrint('[SGTP] PONG: peer $senderHex handshakeComplete=true pendingHandshakes=$_pendingHandshakes peers=${_peers.keys.toList()}');

    if (!_eventController.isClosed && existingPeer?.handshakeComplete != true) {
      _eventController.add(SgtpPeerJoined(peerUUID: senderHex));
    }

    await _checkAndSendChatRequest();
  }

  Future<void> _sendInfoRequest() async {
    final master = _getMasterUUID();
    if (master == null) {
      debugPrint('[SGTP] _sendInfoRequest: no peers yet, skipping');
      return;
    }
    final masterHex = uuidBytesToHex(master);
    debugPrint('[SGTP] sending INFO request to master $masterHex');
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
    final myHex = uuidBytesToHex(_myUUID);
    debugPrint('[SGTP] INFO response: ${uuids.length} UUIDs received');

    for (final uuid in uuids) {
      final uuidHex = uuidBytesToHex(uuid);
      if (uuidHex == myHex) continue;
      if (_peers.containsKey(uuidHex)) continue;

      debugPrint('[SGTP] INFO response: unknown peer $uuidHex → PING + pending');
      _pendingHandshakes.add(uuidHex);
      await _sendPing(uuid);
    }

    if (_pendingHandshakes.isEmpty) {
      debugPrint('[SGTP] INFO response: no new peers discovered');
      await _checkAndSendChatRequest();
    }
  }

  Future<void> _checkAndSendChatRequest() async {
    // A peer is "ready" if we have a shared secret with them (sharedKey non-empty).
    // handshakeComplete is set only when we receive their PONG, but the master may
    // send CHAT_KEY before we receive a PONG (they already have our X25519 pub from
    // our PONG). So we only require sharedKey here.
    final allReady = _peers.values.every((p) => p.sharedKey.isNotEmpty);
    debugPrint('[SGTP] _checkAndSendChatRequest: chatRequestSent=$_chatRequestSent pending=$_pendingHandshakes peers=${_peers.keys.toList()} allReady=$allReady');

    if (_chatRequestSent) {
      debugPrint('[SGTP] _checkAndSendChatRequest: already sent, skipping');
      return;
    }
    if (_pendingHandshakes.isNotEmpty) {
      debugPrint('[SGTP] _checkAndSendChatRequest: pending handshakes not empty, waiting');
      return;
    }
    if (_peers.isEmpty) {
      debugPrint('[SGTP] _checkAndSendChatRequest: no peers yet');
      return;
    }
    if (!allReady) {
      final notReady = _peers.entries
          .where((e) => e.value.sharedKey.isEmpty)
          .map((e) => e.key)
          .toList();
      debugPrint('[SGTP] _checkAndSendChatRequest: peers without shared key: $notReady');
      return;
    }

    _updateMasterStatus();
    debugPrint('[SGTP] _checkAndSendChatRequest: isMaster=$_isMaster');

    if (!_isMaster) {
      final masterUUID = _getMasterUUID();
      if (masterUUID == null) return;
      final masterHex = uuidBytesToHex(masterUUID);
      final knownUUIDs = _peers.values.map((p) => p.uuidBytes).toList();
      debugPrint('[SGTP] sending CHAT_REQUEST to master $masterHex with ${knownUUIDs.length} known UUIDs');
      final frame = buildChatRequest(_roomUUID, masterUUID, _myUUID, knownUUIDs);
      await _sendFrame(frame);
      _chatRequestSent = true;
    } else {
      _chatRequestSent = true;
      debugPrint('[SGTP] master: issuing CHAT_KEY to all peers');
      await _issueChatKeyToAll();
    }
  }

  Future<void> _handleChatRequest(ParsedFrame frame) async {
    if (!_isMaster) return;
    await _issueChatKeyToAll();
  }

  Future<void> _issueChatKeyToAll() async {
    if (_peers.isEmpty) {
      debugPrint('[SGTP] _issueChatKeyToAll: no peers, skipping');
      return;
    }

    final rng = Random.secure();
    final newKey = Uint8List.fromList(List.generate(32, (i) => rng.nextInt(256)));

    _chatKey = newKey;
    _chatEpoch = DateTime.now().millisecondsSinceEpoch;
    _myNonce = 0;
    debugPrint('[SGTP] _issueChatKeyToAll: new chatKey generated epoch=$_chatEpoch, sending to ${_peers.length} peers');

    for (final peer in _peers.values) {
      if (peer.sharedKey.isEmpty) continue;
      try {
        final encryptedKey = await encrypt(newKey, peer.sharedKey, _chatEpoch);
        debugPrint('[SGTP] sending CHAT_KEY to peer=${peer.uuid}');
        final frame = buildChatKey(_roomUUID, peer.uuidBytes, _myUUID, _chatEpoch, encryptedKey);
        await _sendFrame(frame);
      } catch (e) {
        debugPrint('[SGTP] failed to send CHAT_KEY to ${peer.uuid}: $e');
        _eventController.add(SgtpError(error: 'Failed to send CHAT_KEY to ${peer.uuid}: $e'));
      }
    }

    if (!_readyEmitted) {
      _readyEmitted = true;
      _state = _ClientState.ready;
      debugPrint('[SGTP] master emitting SgtpReady');
      _eventController.add(SgtpReady(isMaster: true, roomUUIDHex: uuidBytesToHex(_roomUUID)));
    }

    _ckRotationTimer?.cancel();
    _ckRotationTimer = Timer(
        const Duration(seconds: SgtpConstants.ckRotationInterval), _rotateChatKey);
  }

  Future<void> _rotateChatKey() async {
    if (_state == _ClientState.ready && _isMaster) {
      await _issueChatKeyToAll();
    }
  }

  Future<void> _handleChatKey(ParsedFrame frame) async {
    debugPrint('[SGTP] CHAT_KEY received payloadLen=${frame.payloadLength} minRequired=${SgtpConstants.chatKeyPayloadLength}');

    if (frame.payloadLength < SgtpConstants.chatKeyPayloadLength) {
      debugPrint('[SGTP] CHAT_KEY payload too short, dropping');
      return;
    }

    final epoch = frame.epoch;
    final encryptedKey = frame.encryptedChatKey;
    final senderHex = uuidBytesToHex(frame.senderUUID);
    final peer = _peers[senderHex];
    debugPrint('[SGTP] CHAT_KEY from $senderHex peerKnown=${peer != null} sharedKeyLen=${peer?.sharedKey.length} handshakeComplete=${peer?.handshakeComplete}');

    if (peer == null || peer.sharedKey.isEmpty) {
      debugPrint('[SGTP] CHAT_KEY: peer not known or shared key missing, dropping');
      return;
    }

    try {
      debugPrint('[SGTP] CHAT_KEY: decrypting with epoch=$epoch encryptedKeyLen=${encryptedKey.length}');
      final decryptedKey = await decrypt(encryptedKey, peer.sharedKey, epoch);
      debugPrint('[SGTP] CHAT_KEY: decrypted key length=${decryptedKey.length}');
      if (decryptedKey.length != 32) {
        debugPrint('[SGTP] CHAT_KEY: bad decrypted key length ${decryptedKey.length} (expected 32)');
        return;
      }

      _chatKey = Uint8List.fromList(decryptedKey);
      _chatEpoch = epoch;
      _myNonce = 0;

      debugPrint('[SGTP] CHAT_KEY: sending ACK');
      final ackFrame = buildChatKeyAck(_roomUUID, frame.senderUUID, _myUUID);
      await _sendFrame(ackFrame);

      if (!_readyEmitted) {
        _readyEmitted = true;
        _state = _ClientState.ready;
        debugPrint('[SGTP] CHAT_KEY: emitting SgtpReady(isMaster=false)');
        _eventController.add(SgtpReady(isMaster: false, roomUUIDHex: uuidBytesToHex(_roomUUID)));
      }
    } catch (e) {
      debugPrint('[SGTP] CHAT_KEY: decryption failed: $e');
      _eventController.add(SgtpError(error: 'Failed to decrypt CHAT_KEY: $e'));
    }
  }

  Future<void> _handleMessage(ParsedFrame frame) async {
    if (_chatKey == null) return;
    if (frame.payloadLength < 24 + 16) return;

    final senderHex = uuidBytesToHex(frame.senderUUID);
    final myHex = uuidBytesToHex(_myUUID);
    if (senderHex == myHex) return;

    try {
      final nonce = frame.messageNonce;
      final ciphertext = frame.messageCiphertext;
      final plaintext = await decrypt(ciphertext, _chatKey!, nonce);
      final raw = utf8.decode(plaintext);
      final msgUUID = uuidBytesToHex(frame.messageUUID);

      // Try to parse as ChatPayload JSON; fall back to plain text
      Map<String, dynamic>? payload;
      try {
        payload = json.decode(raw) as Map<String, dynamic>;
      } catch (e) {
        // not JSON
      }

      if (payload == null || payload['v'] != 1) {
        // Legacy plain text
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

      if (type == 'text') {
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
      } else if (type == 'image') {
        await _handleImagePayload(msgUUID, senderHex, payload);
      }
    } catch (e) {
      // Decryption failed - possibly old epoch
    }
  }

  Future<void> _handleImagePayload(
    String msgUUID,
    String senderHex,
    Map<String, dynamic> payload,
  ) async {
    final fileId = payload['file_id'] as String? ?? msgUUID;
    final name = payload['name'] as String? ?? 'image';
    final mime = payload['mime'] as String? ?? 'image/jpeg';
    final totalSize = (payload['size'] as num?)?.toInt() ?? 0;
    final dataB64 = payload['data'] as String? ?? '';
    final chunkBytes = base64.decode(dataB64);

    // Single-frame image (no chunk fields)
    if (!payload.containsKey('chunk')) {
      _eventController.add(SgtpMessageReceived(
        message: ChatMessage(
          id: msgUUID,
          senderUUID: senderHex,
          content: name,
          imageBytes: chunkBytes,
          type: MessageType.image,
          receivedAt: DateTime.now(),
          isFromHistory: false,
          isFromMe: false,
        ),
      ));
      return;
    }

    // Chunked image
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
        message: ChatMessage(
          id: fileId,
          senderUUID: senderHex,
          content: name,
          imageBytes: assembled,
          type: MessageType.image,
          receivedAt: DateTime.now(),
          isFromHistory: false,
          isFromMe: false,
        ),
      ));
    }
  }

  void _handleFin(ParsedFrame frame) {
    final senderHex = uuidBytesToHex(frame.senderUUID);
    _peers.remove(senderHex);
    _pendingHandshakes.remove(senderHex);
    _eventController.add(SgtpPeerLeft(peerUUID: senderHex));
  }

  // ---------------------------------------------------------------------------
  // Internal: helpers
  // ---------------------------------------------------------------------------

  Future<void> _sendPing(Uint8List receiverUUID) async {
    if (_ephemeralX25519Pub == null) return;

    final frame = buildPingFrame(
      _roomUUID,
      receiverUUID,
      _myUUID,
      _ephemeralX25519Pub!,
      _config.myPublicKey,
    );
    await _sendFrame(frame);
  }

  Future<void> _sendPong(Uint8List receiverUUID) async {
    if (_ephemeralX25519Pub == null) return;

    final frame = buildPongFrame(
      _roomUUID,
      receiverUUID,
      _myUUID,
      _ephemeralX25519Pub!,
      _config.myPublicKey,
    );
    await _sendFrame(frame);
  }

  Future<void> _sendFrame(Uint8List unsignedFrame) async {
    try {
      final signed = await signFrame(unsignedFrame, _config.identityKeyPair);
      _socket?.add(signed);
    } catch (e) {
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

  /// Get the UUID bytes of the peer with the smallest UUID (the master).
  Uint8List? _getMasterUUID() {
    if (_peers.isEmpty) return null;

    Uint8List? smallest;
    for (final peer in _peers.values) {
      if (smallest == null || compareBytes(peer.uuidBytes, smallest) < 0) {
        smallest = peer.uuidBytes;
      }
    }

    // Compare with own UUID
    if (compareBytes(_myUUID, smallest!) < 0) {
      return _myUUID; // I am master
    }

    return smallest;
  }

  Future<void> _cleanup() async {
    _state = _ClientState.disconnected;
    _ckRotationTimer?.cancel();
    _ckRotationTimer = null;
    _infoTimerStarted = false;
    _chatRequestSent = false;
    _readyEmitted = false;
    _peers.clear();
    _pendingHandshakes.clear();
    _pendingFiles.clear();
    _chatKey = null;
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
