// Обновления для lib/data/sgtp_client.dart

// ====== SgtpConfig ======

// Добавить в класс SgtpConfig:

class SgtpConfig {
  final String serverAddr;
  final Uint8List roomUUID;
  final SimpleKeyPairData identityKeyPair;
  final Uint8List myPublicKey;
  final Set<String> whitelist;
  
  // NEW: Chat metadata
  final ChatMetadata? chatMetadata;

  const SgtpConfig({
    required this.serverAddr,
    required this.roomUUID,
    required this.identityKeyPair,
    required this.myPublicKey,
    required this.whitelist,
    this.chatMetadata,  // NEW
  });

  SgtpConfig copyWithRoomUUID(Uint8List roomUUID) => SgtpConfig(
    serverAddr: serverAddr,
    roomUUID: roomUUID,
    identityKeyPair: identityKeyPair,
    myPublicKey: myPublicKey,
    whitelist: whitelist,
    chatMetadata: chatMetadata,
  );

  // NEW: Copy with chat metadata
  SgtpConfig copyWithChatMetadata(ChatMetadata? metadata) => SgtpConfig(
    serverAddr: serverAddr,
    roomUUID: roomUUID,
    identityKeyPair: identityKeyPair,
    myPublicKey: myPublicKey,
    whitelist: whitelist,
    chatMetadata: metadata,
  );
}

// ====== SgtpClient ======

// В классе SgtpClient добавить поля для метаданных чата:

class SgtpClient {
  final SgtpConfig _config;
  
  // ... существующие поля ...
  
  // NEW: Chat metadata handling
  String? _currentChatName;
  Uint8List? _currentChatAvatar;
  late final StreamController<SgtpEvent> events = StreamController<SgtpEvent>.broadcast();

  SgtpClient(this._config) {
    _currentChatName = _config.chatMetadata?.name ?? 'Chat';
    _currentChatAvatar = _config.chatMetadata?.avatarBytes;
    
    // ... инициализация существующего кода ...
  }

  // NEW: Обновить метаданные чата и переотправить CHAT_REQUEST
  Future<void> updateChatMetadata(String newName, Uint8List? newAvatar) async {
    _currentChatName = newName;
    _currentChatAvatar = newAvatar;
    
    // Переотправить CHAT_REQUEST с новыми метаданными
    await _checkChatReq();
  }

  // NEW: Get current chat metadata
  (String name, Uint8List? avatar) getChatMetadata() {
    return (_currentChatName ?? 'Chat', _currentChatAvatar);
  }
}

// ====== В _checkChatReq() ======

// Обновить функцию _checkChatReq() в sgtp_client.dart:

Future<void> _checkChatReq() async {
  debugPrint('[SGTP] checkChatReq: sent=$_chatRequestSent pending=$_pendingHandshakes');
  if (_chatRequestSent || _pendingHandshakes.isNotEmpty) return;
  if (_peers.isNotEmpty && !_peers.values.every((p) => p.sharedKey.isNotEmpty)) return;
  
  _updateMaster();
  
  if (!_isMaster) {
    final m = _masterPeer();
    if (m == null) return;
    
    // NEW: Include chat metadata
    await _sendFrame(buildChatRequest(
      _roomUUID,
      m,
      _myUUID,
      _peers.values.map((p) => p.uuidBytes).toList(),
      chatName: _currentChatName ?? 'Chat',
      chatAvatarBytes: _currentChatAvatar,
    ));
    _chatRequestSent = true;
    debugPrint('[SGTP] sent CHAT_REQUEST with metadata: $_currentChatName');
  } else {
    _chatRequestSent = true;
    await _issueCK();
  }
}

// ====== В _onChatRequest() ======

// Обновить обработку входящего CHAT_REQUEST:

Future<void> _onChatRequest(ParsedFrame f) async {
  final sender = uuidBytesToHex(f.senderUUID);
  debugPrint('[SGTP] CHAT_REQUEST from $sender');
  
  // NEW: Parse chat metadata from the request
  try {
    final parsed = parseChatRequest(f.payload);
    
    // Emit event с метаданными
    events.add(SgtpChatRequestReceived(
      senderUUID: sender,
      chatName: parsed.chatName,
      avatarBytes: parsed.avatarBytes,
      peerUUIDs: parsed.peerUUIDs.map(uuidBytesToHex).toList(),
    ));
    
    debugPrint('[SGTP] Chat metadata: ${parsed.chatName}');
  } catch (e) {
    debugPrint('[SGTP] Error parsing chat request: $e');
  }

  if (_chatKey != null) {
    await _issueCKToPeer(sender);
  } else {
    await _issueCK();
  }
}

// ====== Импорты ======

// Добавить в начало файла:
import '../domain/entities/chat_metadata.dart';
import '../core/protocol/frame_parser.dart';  // Для parseChatRequest

// ====== Helper для преобразования UUID ======

String uuidBytesToHex(Uint8List bytes) {
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

Uint8List hexToUuidBytes(String hex) {
  final chunks = <int>[];
  for (int i = 0; i < hex.length; i += 2) {
    chunks.add(int.parse(hex.substring(i, i + 2), radix: 16));
  }
  return Uint8List.fromList(chunks);
}
