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
  final List<Uint8List?> chunks;

  _PendingFile({
    required this.fileId, required this.name, required this.mime,
    required this.totalSize, required this.totalChunks,
    required this.senderUUID, required this.mediaType,
  }) : chunks = List.filled(totalChunks, null);

  bool get isComplete => chunks.every((c) => c != null);
  Uint8List assemble() {
    final buf = BytesBuilder();
    for (final c in chunks) buf.add(c!);
    return buf.takeBytes();
  }
}

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

class SgtpConfig {
  final String serverAddr;
  final Uint8List roomUUID;
  final SimpleKeyPairData identityKeyPair;
  final Uint8List myPublicKey;
  final Set<String> whitelist;
  const SgtpConfig({
    required this.serverAddr, required this.roomUUID,
    required this.identityKeyPair, required this.myPublicKey,
    required this.whitelist,
  });
}

// ---------------------------------------------------------------------------
// Events
// ---------------------------------------------------------------------------

sealed class SgtpEvent {}
class SgtpConnecting  extends SgtpEvent {}
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

  final _eventController = StreamController<SgtpEvent>.broadcast();
  Stream<SgtpEvent> get events => _eventController.stream;

  Socket? _socket;
  final List<int> _receiveBuffer = [];
  _ClientState _state = _ClientState.disconnected;

  final Map<String, PeerInfo> _peers = {};
  SimpleKeyPair? _ephemeralX25519;
  Uint8List?     _ephemeralX25519Pub;

  Uint8List? _chatKey;
  int _chatEpoch = 0;
  int _myNonce   = 0;

  final Map<String, _PendingFile> _pendingFiles = {};

  bool   _isMaster         = false;
  Timer? _ckRotationTimer;
  bool   _infoTimerStarted  = false;
  final Set<String> _pendingHandshakes = {};
  bool   _chatRequestSent   = false;
  bool   _readyEmitted       = false;

  /// Last time (ms) we received any frame from a peer. Used to detect zombies.
  final Map<String, int> _peerLastSeen = {};
  Timer? _stalePruneTimer;

  // History
  final List<_HistoryRecord> _historyStore = [];
  bool _historyRequested = false;
  final Map<String, int> _hsiReplies = {};
  Timer? _hsiTimer;

  // High bit to distinguish history re-encrypted nonces from live ones
  static const int _histNonceBit = 1 << 62;

  SgtpClient(SgtpConfig config)
      : _config = config,
        _myUUID = generateUUIDv7() {
    _roomUUID = config.roomUUID.every((b) => b == 0)
        ? generateUUIDv7()
        : Uint8List.fromList(config.roomUUID);
  }

  bool get isMaster    => _isMaster;
  String get myUUIDHex   => uuidBytesToHex(_myUUID);
  String get roomUUIDHex => uuidBytesToHex(_roomUUID);
  List<String> get peerUUIDs => _peers.keys.toList();

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  Future<void> connect() async {
    if (_state != _ClientState.disconnected) return;
    _state = _ClientState.connecting;
    _eventController.add(SgtpConnecting());
    try {
      _ephemeralX25519    = await generateEphemeralKeyPair();
      _ephemeralX25519Pub = await extractPublicKeyBytes(_ephemeralX25519!);
      final parts = _config.serverAddr.split(':');
      _socket = await Socket.connect(parts[0], int.parse(parts.last));
      _state  = _ClientState.waitingHandshake;
      _eventController.add(SgtpHandshaking());
      _socket!.listen(_onData,
          onError: _onSocketError, onDone: _onSocketDone, cancelOnError: false);
      _stalePruneTimer = Timer.periodic(const Duration(seconds: 60),
          (_) => _pruneStale());
      await _sendFrame(buildIntentFrame(_roomUUID, _myUUID));
      // If no peers respond within infoDelayMs, go ready solo.
      Future.delayed(Duration(milliseconds: SgtpConstants.infoDelayMs), () async {
        if (_state == _ClientState.waitingHandshake && _peers.isEmpty && !_readyEmitted) {
          debugPrint('[SGTP] no peers after delay, going ready solo');
          _updateMaster();
          _chatRequestSent = true;
          await _issueCK();
        }
      });
    } catch (e) {
      _state = _ClientState.disconnected;
      _eventController.add(SgtpError(error: 'Connection failed: $e'));
    }
  }

  Future<void> sendMessage(String text) async {
    if (_state != _ClientState.ready || _chatKey == null) return;
    final msgUUID   = generateUUIDv7();
    final nonce     = _myNonce++;
    final plaintext = Uint8List.fromList(
        utf8.encode(json.encode({'v': 1, 'type': 'text', 'text': text})));
    try {
      final cipher = await encrypt(plaintext, _chatKey!, nonce);
      await _sendFrame(buildMessage(_roomUUID, _myUUID, msgUUID, nonce, cipher));
      _historyStore.add(_HistoryRecord(
        senderUUID: _myUUID, messageUUID: msgUUID,
        timestamp: DateTime.now().millisecondsSinceEpoch, nonce: nonce,
        plaintext: plaintext,
      ));
      _eventController.add(SgtpMessageReceived(message: ChatMessage(
        id: uuidBytesToHex(msgUUID), senderUUID: uuidBytesToHex(_myUUID),
        content: text, receivedAt: DateTime.now(), isFromHistory: false, isFromMe: true,
      )));
    } catch (e) {
      _eventController.add(SgtpError(error: 'Failed to send message: $e'));
    }
  }

  Future<void> _sendMedia(
    Uint8List bytes, String name, String mime, String mediaType,
    {ChatMessage? echoMessage}) async {
    if (_state != _ClientState.ready || _chatKey == null) return;
    const chunkSize   = SgtpConstants.mediaChunkSize;
    final fileId      = uuidBytesToHex(generateUUIDv7());
    final totalChunks = (bytes.length / chunkSize).ceil().clamp(1, 9999);
    try {
      for (int i = 0; i < totalChunks; i++) {
        final start = i * chunkSize;
        final end   = (start + chunkSize).clamp(0, bytes.length);
        final Map<String, dynamic> payload = {
          'v': 1, 'type': mediaType, 'file_id': fileId,
          'name': name, 'mime': mime, 'size': bytes.length,
          'data': base64.encode(bytes.sublist(start, end)),
        };
        if (totalChunks > 1) { payload['chunk'] = i; payload['chunks'] = totalChunks; }
        final msgUUID = generateUUIDv7();
        final nonce   = _myNonce++;
        final plain   = Uint8List.fromList(utf8.encode(json.encode(payload)));
        final cipher  = await encrypt(plain, _chatKey!, nonce);
        await _sendFrame(buildMessage(_roomUUID, _myUUID, msgUUID, nonce, cipher));
      }
      if (echoMessage != null) {
        _eventController.add(SgtpMessageReceived(message: echoMessage));
      }
    } catch (e) {
      _eventController.add(SgtpError(error: 'Failed to send $mediaType: $e'));
    }
  }

  Future<void> sendImage(Uint8List bytes, String name, String mime) =>
      _sendMedia(bytes, name, mime, mime == 'image/gif' ? 'gif' : 'image',
          echoMessage: ChatMessage(
            id: uuidBytesToHex(generateUUIDv7()), senderUUID: uuidBytesToHex(_myUUID),
            content: name, imageBytes: bytes, mediaMime: mime, mediaName: name,
            type: mime == 'image/gif' ? MessageType.gif : MessageType.image,
            receivedAt: DateTime.now(), isFromHistory: false, isFromMe: true));

  Future<void> sendVideo(Uint8List bytes, String name, String mime) =>
      _sendMedia(bytes, name, mime, 'video',
          echoMessage: ChatMessage(
            id: uuidBytesToHex(generateUUIDv7()), senderUUID: uuidBytesToHex(_myUUID),
            content: name, videoBytes: bytes, mediaMime: mime, mediaName: name,
            type: MessageType.video, receivedAt: DateTime.now(),
            isFromHistory: false, isFromMe: true));

  Future<void> sendVoice(Uint8List bytes, String mime) {
    final name = 'voice_${DateTime.now().millisecondsSinceEpoch}.${_ext(mime)}';
    return _sendMedia(bytes, name, mime, 'voice',
        echoMessage: ChatMessage(
          id: uuidBytesToHex(generateUUIDv7()), senderUUID: uuidBytesToHex(_myUUID),
          content: name, audioBytes: bytes, mediaMime: mime, mediaName: name,
          type: MessageType.voice, receivedAt: DateTime.now(),
          isFromHistory: false, isFromMe: true));
  }

  String _ext(String mime) => switch (mime) {
    'audio/m4a' => 'm4a', 'audio/aac' => 'aac',
    'audio/opus' => 'opus', 'audio/mpeg' => 'mp3', _ => 'audio',
  };

  Future<void> disconnect() async {
    if (_state == _ClientState.disconnected) return;
    try {
      if (_chatKey != null) {
        final nonce = _myNonce++;
        final tag   = await encrypt(Uint8List(0), _chatKey!, nonce);
        await _sendFrame(buildFin(_roomUUID, _myUUID, nonce, tag.sublist(0, 16)));
      }
    } catch (_) {}
    await _cleanup();
  }

  // ---------------------------------------------------------------------------
  // Socket
  // ---------------------------------------------------------------------------

  void _onData(List<int> data) {
    _receiveBuffer.addAll(data);
    _processBuffer();
  }

  void _onSocketError(Object e) {
    _eventController.add(SgtpError(error: 'Socket error: $e'));
    _cleanup();
  }

  void _onSocketDone() {
    if (_state != _ClientState.disconnected) {
      _cleanup();
      _eventController.add(SgtpDisconnected());
    }
  }

  void _processBuffer() {
    while (true) {
      final r = tryExtractFrame(_receiveBuffer);
      if (r == null) break;
      _receiveBuffer.removeRange(0, r.bytesConsumed);
      _handleFrame(r.frame);
    }
  }

  // ---------------------------------------------------------------------------
  // Dispatch
  // ---------------------------------------------------------------------------

  void _handleFrame(ParsedFrame frame) async {
    try { await _dispatch(frame); } catch (e) {
      debugPrint('[SGTP] frame error: $e');
    }
  }

  bool _tsOk(int ts) =>
      (DateTime.now().millisecondsSinceEpoch - ts).abs() <= SgtpConstants.timestampWindow;

  Future<void> _dispatch(ParsedFrame frame) async {
    if (!_tsOk(frame.timestamp)) return;
    // Track when we last heard from this peer.
    final frameSender = uuidBytesToHex(frame.senderUUID);
    if (_peers.containsKey(frameSender)) {
      _peerLastSeen[frameSender] = DateTime.now().millisecondsSinceEpoch;
    }
    switch (frame.packetType) {
      case PacketType.intent:      await _onIntent(frame);
      case PacketType.ping:        await _onPing(frame);
      case PacketType.pong:        await _onPong(frame);
      case PacketType.info:
        if (frame.payloadLength == 0) await _onInfoReq(frame);
        else                          await _onInfoResp(frame);
      case PacketType.chatRequest: if (_isMaster) await _onChatRequest(frame);
      case PacketType.chatKey:     await _onChatKey(frame);
      case PacketType.chatKeyAck:  break;
      case PacketType.message:     await _onMessage(frame);
      case PacketType.messageFailed: await _onMsgFailed(frame);
      case PacketType.status:      await _onStatus(frame);
      case PacketType.fin:         await _onFin(frame);
      case PacketType.kicked:      _onKicked(frame);
      case PacketType.hsir:        await _onHsir(frame);
      case PacketType.hsi:         _onHsi(frame);
      case PacketType.hsr:         await _onHsr(frame);
      case PacketType.hsra:        await _onHsra(frame);
      default: break;
    }
  }

  // ---------------------------------------------------------------------------
  // Handshake
  // ---------------------------------------------------------------------------

  Future<void> _onIntent(ParsedFrame f) async {
    final h = uuidBytesToHex(f.senderUUID);
    if (h == myUUIDHex) return;
    debugPrint('[SGTP] INTENT from $h peers=${_peers.keys.toList()} isMaster=$_isMaster state=$_state');
    await _pruneStale(thresholdMs: 30 * 1000);
    await _sendPing(f.senderUUID);
  }

  /// Remove peers that haven't sent any frame for [thresholdMs] milliseconds,
  /// then re-evaluate master status and issue a new chat key if we became master.
  Future<void> _pruneStale({int thresholdMs = 300 * 1000}) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final stale = _peers.keys.where((h) {
      final seen = _peerLastSeen[h] ?? 0;
      return now - seen > thresholdMs;
    }).toList();

    if (stale.isEmpty) return;

    for (final h in stale) {
      debugPrint('[SGTP] pruning stale peer $h (silent for >${thresholdMs ~/ 1000}s)');
      _peers.remove(h);
      _peerLastSeen.remove(h);
      _pendingHandshakes.remove(h);
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
        // We're alone — stay ready, reset chatRequestSent so next joiner works.
        _chatRequestSent = false;
      }
    }
  }

  Future<void> _onPing(ParsedFrame f) async {
    final h = uuidBytesToHex(f.senderUUID);
    if (h == myUUIDHex) return;
    debugPrint('[SGTP] PING from $h payloadLen=${f.payloadLength}');
    if (f.payloadLength < SgtpConstants.pingPayloadMinLength) {
      debugPrint('[SGTP] PING too short, drop');
      return;
    }
    final ed  = f.ed25519PubKey;
    final edH = _hex(ed);
    final inWl = _config.whitelist.contains(edH);
    debugPrint('[SGTP] PING ed25519=${edH.substring(0,16)}... inWhitelist=$inWl');
    if (!inWl) { debugPrint('[SGTP] PING not in whitelist, drop'); return; }
    final sigOk = await verifyFrame(f.raw, ed);
    debugPrint('[SGTP] PING sigOk=$sigOk');
    if (!sigOk) { debugPrint('[SGTP] PING bad sig, drop'); return; }
    if (f.payloadLength >= SgtpConstants.pingPayloadLength) {
      final hello = ascii.decode(f.payload.sublist(64, 76), allowInvalid: true);
      debugPrint('[SGTP] PING clientHello="$hello" expected="${SgtpConstants.clientHello}"');
      if (hello != SgtpConstants.clientHello) { debugPrint('[SGTP] PING hello mismatch, drop'); return; }
    }
    final ss   = await computeSharedSecret(_ephemeralX25519!, f.x25519PubKey);
    final prev = _peers[h];
    _peers[h]  = PeerInfo(uuid: h, uuidBytes: Uint8List.fromList(f.senderUUID),
        ed25519PubKey: ed, sharedKey: ss, handshakeComplete: prev?.handshakeComplete ?? false);
    _peerLastSeen[h] = DateTime.now().millisecondsSinceEpoch;
    debugPrint('[SGTP] PING ok → sending PONG, state=$_state isMaster=$_isMaster');
    await _sendPong(f.senderUUID);
    _scheduleInfo();
    if (!_eventController.isClosed) {
      _eventController.add(SgtpPeerJoined(peerUUID: h, ed25519PubHex: edH));
    }
  }

  Future<void> _onPong(ParsedFrame f) async {
    final h = uuidBytesToHex(f.senderUUID);
    if (h == myUUIDHex) return;
    debugPrint('[SGTP] PONG from $h payloadLen=${f.payloadLength}');
    if (f.payloadLength < SgtpConstants.pingPayloadMinLength) {
      debugPrint('[SGTP] PONG too short, drop');
      return;
    }
    final ed  = f.ed25519PubKey;
    final edH = _hex(ed);
    final inWl = _config.whitelist.contains(edH);
    debugPrint('[SGTP] PONG ed25519=${edH.substring(0,16)}... inWhitelist=$inWl');
    if (!inWl) { debugPrint('[SGTP] PONG not in whitelist, drop'); return; }
    final sigOk = await verifyFrame(f.raw, ed);
    debugPrint('[SGTP] PONG sigOk=$sigOk');
    if (!sigOk) { debugPrint('[SGTP] PONG bad sig, drop'); return; }
    if (f.payloadLength >= SgtpConstants.pingPayloadLength) {
      final hello = ascii.decode(f.payload.sublist(64, 76), allowInvalid: true);
      debugPrint('[SGTP] PONG clientHello="$hello" expected="${SgtpConstants.clientHello}"');
      if (hello != SgtpConstants.clientHello) { debugPrint('[SGTP] PONG hello mismatch, drop'); return; }
    }
    final ss   = await computeSharedSecret(_ephemeralX25519!, f.x25519PubKey);
    final prev = _peers[h];
    _peers[h]  = PeerInfo(uuid: h, uuidBytes: Uint8List.fromList(f.senderUUID),
        ed25519PubKey: ed, sharedKey: ss, handshakeComplete: true);
    _peerLastSeen[h] = DateTime.now().millisecondsSinceEpoch;
    _pendingHandshakes.remove(h);
    debugPrint('[SGTP] PONG ok peer=$h state=$_state isMaster=$_isMaster peers=${_peers.keys.toList()} pending=$_pendingHandshakes');
    if (!_eventController.isClosed && prev?.handshakeComplete != true) {
      _eventController.add(SgtpPeerJoined(peerUUID: h, ed25519PubHex: edH));
    }
    if (_state == _ClientState.ready && _isMaster) {
      debugPrint('[SGTP] PONG: already ready+master → issueCKToPeer $h');
      await _issueCKToPeer(h);
    } else {
      debugPrint('[SGTP] PONG: not ready/master → scheduleInfo + checkChatReq');
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
      debugPrint('[SGTP] scheduleInfo fired isMaster=$_isMaster peers=${_peers.keys.toList()}');
      if (_isMaster) { await _checkChatReq(); return; }
      final m = _masterPeer();
      debugPrint('[SGTP] scheduleInfo masterPeer=${m != null ? _hex(m).substring(0,8) : 'null'}');
      if (m == null) return;
      await _sendFrame(buildInfoRequest(_roomUUID, m, _myUUID));
    });
  }

  Future<void> _onInfoReq(ParsedFrame f) async {
    final peers = _peers.values.map((p) => p.uuidBytes).toList()..add(_myUUID);
    await _sendFrame(buildInfoResponse(_roomUUID, f.senderUUID, _myUUID, peers));
  }

  Future<void> _onInfoResp(ParsedFrame f) async {
    final uuids = f.infoUUIDs.map((u) => uuidBytesToHex(u)).toList();
    debugPrint('[SGTP] INFO_RESP uuids=$uuids');
    bool any = false;
    for (final u in f.infoUUIDs) {
      final h = uuidBytesToHex(u);
      if (h == myUUIDHex || _peers.containsKey(h)) continue;
      _pendingHandshakes.add(h);
      await _sendPing(u);
      any = true;
    }
    if (!any) await _checkChatReq();
  }

  Future<void> _checkChatReq() async {
    debugPrint('[SGTP] checkChatReq: sent=$_chatRequestSent pending=$_pendingHandshakes peers=${_peers.keys.toList()} allKeys=${_peers.values.every((p) => p.sharedKey.isNotEmpty)}');
    if (_chatRequestSent || _pendingHandshakes.isNotEmpty) return;
    if (_peers.isNotEmpty && !_peers.values.every((p) => p.sharedKey.isNotEmpty)) return;
    _updateMaster();
    debugPrint('[SGTP] checkChatReq: isMaster=$_isMaster');
    if (!_isMaster) {
      final m = _masterPeer();
      debugPrint('[SGTP] checkChatReq: master=${m != null ? _hex(m).substring(0,8) : 'null'}');
      if (m == null) return;
      await _sendFrame(buildChatRequest(
          _roomUUID, m, _myUUID, _peers.values.map((p) => p.uuidBytes).toList()));
      _chatRequestSent = true;
      debugPrint('[SGTP] sent CHAT_REQUEST');
    } else {
      _chatRequestSent = true;
      debugPrint('[SGTP] checkChatReq: I am master → issueCK');
      await _issueCK();
    }
  }

  Future<void> _onChatRequest(ParsedFrame f) async {
    final sender = uuidBytesToHex(f.senderUUID);
    debugPrint('[SGTP] CHAT_REQUEST from $sender chatKey=${_chatKey != null}');
    if (_chatKey != null) {
      // Already have a key — send it to this peer without rotating.
      // (Rotation is only done by the periodic timer.)
      debugPrint('[SGTP] CHAT_REQUEST: resending current key to $sender');
      await _issueCKToPeer(sender);
    } else {
      debugPrint('[SGTP] CHAT_REQUEST: no key yet → issueCK');
      await _issueCK();
    }
  }

  /// Send the current chat key to a single peer (no rotation, no nonce reset).
  /// Used when a new peer completes the handshake while the room is already ready.
  Future<void> _issueCKToPeer(String peerHex) async {
    if (_chatKey == null) return;
    final peer = _peers[peerHex];
    if (peer == null || peer.sharedKey.isEmpty) return;
    try {
      final enc = await encrypt(_chatKey!, peer.sharedKey, _chatEpoch);
      await _sendFrame(buildChatKey(_roomUUID, peer.uuidBytes, _myUUID, _chatEpoch, enc));
      debugPrint('[SGTP] sent current CHAT_KEY to late-joining peer $peerHex');
    } catch (e) {
      debugPrint('[SGTP] _issueCKToPeer failed for $peerHex: $e');
    }
  }

  Future<void> _issueCK() async {
    debugPrint('[SGTP] issueCK peers=${_peers.keys.toList()} readyEmitted=$_readyEmitted');
    final key = Uint8List.fromList(
        List.generate(32, (_) => Random.secure().nextInt(256)));
    _chatKey   = key;
    final ts   = DateTime.now().millisecondsSinceEpoch;
    _chatEpoch = ts > _chatEpoch ? ts : _chatEpoch + 1;
    _myNonce   = 0;
    for (final peer in _peers.values) {
      if (peer.sharedKey.isEmpty) {
        debugPrint('[SGTP] issueCK: skip ${peer.uuid} (no sharedKey)');
        continue;
      }
      try {
        final enc = await encrypt(key, peer.sharedKey, _chatEpoch);
        await _sendFrame(buildChatKey(_roomUUID, peer.uuidBytes, _myUUID, _chatEpoch, enc));
        debugPrint('[SGTP] issueCK: sent CHAT_KEY to ${peer.uuid}');
      } catch (e) {
        debugPrint('[SGTP] issueCK: encrypt failed for ${peer.uuid}: $e');
      }
    }
    if (!_readyEmitted) {
      _readyEmitted = true;
      _state        = _ClientState.ready;
      debugPrint('[SGTP] issueCK: emitting SgtpReady(isMaster=true)');
      _eventController.add(SgtpReady(isMaster: true, roomUUIDHex: roomUUIDHex));
    }
    _ckRotationTimer?.cancel();
    _ckRotationTimer = Timer(
        const Duration(seconds: SgtpConstants.ckRotationInterval), _issueCK);
  }

  Future<void> _onChatKey(ParsedFrame f) async {
    final senderH = uuidBytesToHex(f.senderUUID);
    debugPrint('[SGTP] CHAT_KEY from $senderH payloadLen=${f.payloadLength} required=${SgtpConstants.chatKeyPayloadLength}');
    if (f.payloadLength < SgtpConstants.chatKeyPayloadLength) {
      debugPrint('[SGTP] CHAT_KEY too short, drop');
      return;
    }
    final peer = _peers[senderH];
    debugPrint('[SGTP] CHAT_KEY peer=${peer?.uuid} sharedKeyLen=${peer?.sharedKey.length ?? 0}');
    if (peer == null) { debugPrint('[SGTP] CHAT_KEY sender not in peers, drop'); return; }
    if (peer.sharedKey.isEmpty) { debugPrint('[SGTP] CHAT_KEY no sharedKey yet, drop'); return; }
    try {
      final dec = await decrypt(f.encryptedChatKey, peer.sharedKey, f.epoch);
      debugPrint('[SGTP] CHAT_KEY decrypted len=${dec.length}');
      if (dec.length != 32) { debugPrint('[SGTP] CHAT_KEY wrong key length, drop'); return; }
      _chatKey   = Uint8List.fromList(dec);
      _chatEpoch = f.epoch;
      _myNonce   = 0;
      await _sendFrame(buildChatKeyAck(_roomUUID, f.senderUUID, _myUUID));
      debugPrint('[SGTP] CHAT_KEY accepted, readyEmitted=$_readyEmitted');
      if (!_readyEmitted) {
        _readyEmitted = true;
        _state        = _ClientState.ready;
        debugPrint('[SGTP] CHAT_KEY: emitting SgtpReady(isMaster=false)');
        _eventController.add(SgtpReady(isMaster: false, roomUUIDHex: roomUUIDHex));
        _requestHistory();
      }
    } catch (e) {
      debugPrint('[SGTP] CHAT_KEY decrypt error: $e');
      _eventController.add(SgtpError(error: 'Failed to decrypt CHAT_KEY: $e'));
    }
  }

  // ---------------------------------------------------------------------------
  // Messages
  // ---------------------------------------------------------------------------

  Future<void> _onMessage(ParsedFrame f, {bool history = false}) async {
    if (_chatKey == null || f.payloadLength < 40) return;
    final sH = uuidBytesToHex(f.senderUUID);
    if (!history && sH == myUUIDHex) return;
    try {
      final plain  = await decrypt(f.messageCiphertext, _chatKey!, f.messageNonce);
      final msgId  = uuidBytesToHex(f.messageUUID);
      final recvAt = history
          ? DateTime.fromMillisecondsSinceEpoch(f.timestamp)
          : DateTime.now();

      if (!history) {
        _historyStore.add(_HistoryRecord(
          senderUUID: Uint8List.fromList(f.senderUUID),
          messageUUID: Uint8List.fromList(f.messageUUID),
          timestamp: f.timestamp, nonce: f.messageNonce, plaintext: plain,
        ));
      }

      Map<String, dynamic>? p;
      try { p = json.decode(utf8.decode(plain)) as Map<String, dynamic>; } catch (_) {}
      if (p == null || p['v'] != 1) {
        _eventController.add(SgtpMessageReceived(message: ChatMessage(
          id: msgId, senderUUID: sH, content: utf8.decode(plain),
          receivedAt: recvAt, isFromHistory: history, isFromMe: false)));
        return;
      }
      switch (p['type'] as String?) {
        case 'text':
          _eventController.add(SgtpMessageReceived(message: ChatMessage(
            id: msgId, senderUUID: sH, content: (p['text'] as String?) ?? '',
            receivedAt: recvAt, isFromHistory: history, isFromMe: false)));
        case 'image': await _mediaPayload(msgId, sH, p, 'image', history, recvAt);
        case 'gif':   await _mediaPayload(msgId, sH, p, 'gif',   history, recvAt);
        case 'video': await _mediaPayload(msgId, sH, p, 'video', history, recvAt);
        case 'voice': await _mediaPayload(msgId, sH, p, 'voice', history, recvAt);
      }
    } catch (_) {}
  }

  Future<void> _mediaPayload(
    String id, String sender, Map<String, dynamic> p,
    String type, bool history, DateTime recvAt,
  ) async {
    final fileId     = p['file_id'] as String? ?? id;
    final name       = p['name']    as String? ?? 'file';
    final mime       = p['mime']    as String? ?? 'application/octet-stream';
    final totalSize  = (p['size']   as num?)?.toInt() ?? 0;
    final chunk      = base64.decode(p['data'] as String? ?? '');
    if (!p.containsKey('chunk')) {
      _eventController.add(SgtpMessageReceived(
          message: _media(id, sender, name, mime, type, chunk, history, recvAt)));
      return;
    }
    final ci = (p['chunk'] as num).toInt();
    final ct = (p['chunks'] as num).toInt();
    _pendingFiles.putIfAbsent(fileId, () => _PendingFile(
      fileId: fileId, name: name, mime: mime, totalSize: totalSize,
      totalChunks: ct, senderUUID: sender, mediaType: type));
    final pf = _pendingFiles[fileId]!;
    if (ci < pf.chunks.length) pf.chunks[ci] = chunk;
    if (pf.isComplete) {
      _pendingFiles.remove(fileId);
      _eventController.add(SgtpMessageReceived(
          message: _media(fileId, sender, name, mime, type, pf.assemble(), history, recvAt)));
    }
  }

  ChatMessage _media(String id, String sender, String name, String mime,
      String type, Uint8List bytes, bool history, DateTime recvAt) =>
    switch (type) {
      'gif'   => ChatMessage(id: id, senderUUID: sender, content: name,
          imageBytes: bytes, mediaMime: mime, mediaName: name,
          type: MessageType.gif, receivedAt: recvAt,
          isFromHistory: history, isFromMe: false),
      'video' => ChatMessage(id: id, senderUUID: sender, content: name,
          videoBytes: bytes, mediaMime: mime, mediaName: name,
          type: MessageType.video, receivedAt: recvAt,
          isFromHistory: history, isFromMe: false),
      'voice' => ChatMessage(id: id, senderUUID: sender, content: name,
          audioBytes: bytes, mediaMime: mime, mediaName: name,
          type: MessageType.voice, receivedAt: recvAt,
          isFromHistory: history, isFromMe: false),
      _       => ChatMessage(id: id, senderUUID: sender, content: name,
          imageBytes: bytes, mediaMime: mime, mediaName: name,
          type: MessageType.image, receivedAt: recvAt,
          isFromHistory: history, isFromMe: false),
    };

  // ---------------------------------------------------------------------------
  // History: serve
  // ---------------------------------------------------------------------------

  Future<void> _onHsir(ParsedFrame f) async {
    final h = uuidBytesToHex(f.senderUUID);
    if (h == myUUIDHex) return;
    debugPrint('[SGTP] HSIR from $h → HSI count=${_historyStore.length}');
    await _sendFrame(buildHsi(
        _roomUUID, Uint8List.fromList(f.senderUUID), _myUUID, _historyStore.length));
  }

  Future<void> _onHsr(ParsedFrame f) async {
    final recv = Uint8List.fromList(f.senderUUID);
    if (_chatKey == null || _historyStore.isEmpty) {
      await _sendFrame(buildHsraEos(_roomUUID, recv, _myUUID, 0));
      return;
    }
    int offset = 0, limit = 0;
    if (f.payloadLength >= 16) {
      final bd = ByteData.view(f.payload.buffer, f.payload.offsetInBytes);
      offset = bd.getUint64(0, Endian.big);
      limit  = bd.getUint64(8, Endian.big);
    }
    final all     = _historyStore.skip(offset).toList();
    final toServe = limit > 0 ? all.take(limit).toList() : all;

    const batch = 32;
    int batchNum = 0;
    for (var i = 0; i < toServe.length; i += batch) {
      final slice  = toServe.skip(i).take(batch).toList();
      final frames = <Uint8List>[];
      for (final r in slice) {
        try {
          final nonce  = _histNonceBit | r.nonce;
          final cipher = await encrypt(r.plaintext, _chatKey!, nonce);
          final raw    = buildMessage(_roomUUID,
              Uint8List.fromList(r.senderUUID), Uint8List.fromList(r.messageUUID),
              nonce, cipher);
          // Set receiver field to requester
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
    debugPrint('[SGTP] broadcasting HSIR');
    signFrame(buildHsir(_roomUUID, _myUUID), _config.identityKeyPair)
        .then((f) => _socket?.add(f));
    _hsiTimer?.cancel();
    _hsiTimer = Timer(const Duration(seconds: 2), _sendHsr);
  }

  void _onHsi(ParsedFrame f) {
    final h = uuidBytesToHex(f.senderUUID);
    if (h == myUUIDHex) return;
    _hsiReplies[h] = f.hsiMessageCount;
    debugPrint('[SGTP] HSI from $h count=${f.hsiMessageCount}');
  }

  Future<void> _sendHsr() async {
    if (_hsiReplies.isEmpty) return;
    final best = _hsiReplies.entries.reduce((a, b) => a.value >= b.value ? a : b);
    if (best.value == 0) return;
    final peer = _peers[best.key];
    if (peer == null) return;
    debugPrint('[SGTP] HSR to ${best.key} (${best.value} msgs)');
    await _sendFrame(buildHsr(_roomUUID, peer.uuidBytes, _myUUID, 0, 0));
  }

  Future<void> _onHsra(ParsedFrame f) async {
    if (f.hsraIsEndOfStream) {
      debugPrint('[SGTP] HSRA EOS total=${f.hsraBatchNumber}');
      return;
    }
    debugPrint('[SGTP] HSRA batch=${f.hsraBatchNumber} msgs=${f.hsraMessageCount}');
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
    try {
      final plain = await decrypt(f.payload, peer.sharedKey, f.timestamp);
      if (plain.length >= 16) {
        _eventController.add(SgtpError(error: 'Message rejected (CK rotation)'));
      }
      await _sendFrame(buildMessageFailedAck(_roomUUID, f.senderUUID, _myUUID));
    } catch (_) {}
  }

  Future<void> _onStatus(ParsedFrame f) async {
    final peer = _peers[uuidBytesToHex(f.senderUUID)];
    if (peer == null || peer.sharedKey.isEmpty) return;
    try {
      final plain = await decrypt(f.payload, peer.sharedKey, f.timestamp);
      if (plain.length >= 2) {
        final code = ByteData.view(plain.buffer, plain.offsetInBytes, 2)
            .getUint16(0, Endian.big);
        _eventController.add(SgtpError(error: 'Server status $code'));
      }
    } catch (_) {}
  }

  Future<void> _onFin(ParsedFrame f) async {
    final h = uuidBytesToHex(f.senderUUID);
    if (h == myUUIDHex) return;
    debugPrint('[SGTP] FIN from $h state=$_state peers=${_peers.keys.toList()}');
    if (_chatKey != null && f.payloadLength >= SgtpConstants.finPayloadLength) {
      try { await decrypt(f.finTag, _chatKey!, f.finNonce); }
      catch (_) { debugPrint('[SGTP] FIN bad tag, drop'); return; }
    }
    _peers.remove(h);
    _pendingHandshakes.remove(h);
    _peerLastSeen.remove(h);
    _eventController.add(SgtpPeerLeft(peerUUID: h));
    debugPrint('[SGTP] FIN: peer removed, remaining peers=${_peers.keys.toList()}');
    if (_state == _ClientState.ready) {
      if (_peers.isEmpty) {
        // We're alone — reset so the next joiner works.
        _chatRequestSent = false;
        debugPrint('[SGTP] FIN: no peers left, reset chatRequestSent');
      } else {
        // Re-evaluate master — the departing peer may have been the master.
        _updateMaster();
        if (_isMaster) {
          // Either we were already master (re-issue after peer left) or we just
          // became master (old master left). Either way, rotate and re-distribute.
          _chatRequestSent = true;
          debugPrint('[SGTP] FIN: I am master → issueCK');
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
    _eventController.add(SgtpPeerLeft(peerUUID: h));
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  Future<void> _sendPing(Uint8List r) async {
    if (_ephemeralX25519Pub == null) return;
    await _sendFrame(buildPingFrame(_roomUUID, r, _myUUID,
        _ephemeralX25519Pub!, _config.myPublicKey));
  }

  Future<void> _sendPong(Uint8List r) async {
    if (_ephemeralX25519Pub == null) return;
    await _sendFrame(buildPongFrame(_roomUUID, r, _myUUID,
        _ephemeralX25519Pub!, _config.myPublicKey));
  }

  Future<void> _sendFrame(Uint8List unsigned) async {
    try {
      _socket?.add(await signFrame(unsigned, _config.identityKeyPair));
    } catch (e) {
      _eventController.add(SgtpError(error: 'Failed to send frame: $e'));
    }
  }

  void _updateMaster() {
    final prev = _isMaster;
    _isMaster = _peers.values.every((p) => compareBytes(p.uuidBytes, _myUUID) > 0);
    if (_isMaster != prev) {
      debugPrint('[SGTP] master changed: isMaster=$_isMaster myUUID=$myUUIDHex');
    }
    if (_isMaster) {
      debugPrint('[SGTP] I am master (UUID=$myUUIDHex)');
    } else {
      final masterHex = _masterPeer() != null ? uuidBytesToHex(_masterPeer()!) : '?';
      debugPrint('[SGTP] master is $masterHex (I am $myUUIDHex)');
    }
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
    _ckRotationTimer  = null;
    _hsiTimer         = null;
    _stalePruneTimer  = null;
    _peerLastSeen.clear();
    _infoTimerStarted  = false;
    _chatRequestSent   = false;
    _readyEmitted       = false;
    _historyRequested  = false;
    _isMaster          = false;
    _peers.clear();
    _pendingHandshakes.clear();
    _pendingFiles.clear();
    _hsiReplies.clear();
    _chatKey   = null;
    _chatEpoch = 0;
    _myNonce   = 0;
    _receiveBuffer.clear();
    try { await _socket?.close(); } catch (_) {}
    _socket = null;
  }

  Future<void> close() async {
    await _cleanup();
    await _eventController.close();
  }
}
