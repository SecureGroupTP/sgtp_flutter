import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'package:sgtp_flutter/core/constants.dart';
import 'package:sgtp_flutter/core/sgtp_transport.dart';

class SgtpConfig {
  final String? accountId;
  final String deviceId;
  final String serverAddr;
  final int? discoveryPort;
  final Uint8List roomUUID;
  final SimpleKeyPairData identityKeyPair;
  final Uint8List myPublicKey;
  final SgtpTransportFamily transport;
  final bool useTls;
  final String fakeSni;
  final String? nodeId;
  final String chatName;
  final Uint8List? chatAvatarBytes;
  final bool isDirectMessage;
  final bool bootstrapDirectRoom;
  final String? directPeerPublicKeyHex;
  final int pingIntervalSeconds;
  final int mediaChunkSizeBytes;

  const SgtpConfig({
    this.accountId,
    required this.deviceId,
    required this.serverAddr,
    this.discoveryPort,
    required this.roomUUID,
    required this.identityKeyPair,
    required this.myPublicKey,
    this.transport = SgtpTransportFamily.tcp,
    this.useTls = false,
    this.fakeSni = '',
    this.nodeId,
    this.chatName = 'Chat',
    this.chatAvatarBytes,
    this.isDirectMessage = false,
    this.bootstrapDirectRoom = false,
    this.directPeerPublicKeyHex,
    this.pingIntervalSeconds = 30,
    this.mediaChunkSizeBytes = SgtpConstants.defaultMediaChunkSize,
  });

  SgtpConfig copyWithRoomUUID(Uint8List roomUUID) => SgtpConfig(
        accountId: accountId,
        deviceId: deviceId,
        serverAddr: serverAddr,
        discoveryPort: discoveryPort,
        roomUUID: roomUUID,
        identityKeyPair: identityKeyPair,
        myPublicKey: myPublicKey,
        transport: transport,
        useTls: useTls,
        fakeSni: fakeSni,
        nodeId: nodeId,
        chatName: chatName,
        chatAvatarBytes: chatAvatarBytes,
        isDirectMessage: isDirectMessage,
        bootstrapDirectRoom: bootstrapDirectRoom,
        directPeerPublicKeyHex: directPeerPublicKeyHex,
        pingIntervalSeconds: pingIntervalSeconds,
        mediaChunkSizeBytes: mediaChunkSizeBytes,
      );

  SgtpConfig copyWithMeta({String? name, Uint8List? avatar}) => SgtpConfig(
        accountId: accountId,
        deviceId: deviceId,
        serverAddr: serverAddr,
        discoveryPort: discoveryPort,
        roomUUID: roomUUID,
        identityKeyPair: identityKeyPair,
        myPublicKey: myPublicKey,
        transport: transport,
        useTls: useTls,
        fakeSni: fakeSni,
        nodeId: nodeId,
        chatName: name ?? chatName,
        chatAvatarBytes: avatar ?? chatAvatarBytes,
        isDirectMessage: isDirectMessage,
        bootstrapDirectRoom: bootstrapDirectRoom,
        directPeerPublicKeyHex: directPeerPublicKeyHex,
        pingIntervalSeconds: pingIntervalSeconds,
        mediaChunkSizeBytes: mediaChunkSizeBytes,
      );

  SgtpConfig copyWithDirectRoom({
    required bool isDirectMessage,
    bool? bootstrapDirectRoom,
    String? directPeerPublicKeyHex,
  }) {
    return SgtpConfig(
      accountId: accountId,
      deviceId: deviceId,
      serverAddr: serverAddr,
      discoveryPort: discoveryPort,
      roomUUID: roomUUID,
      identityKeyPair: identityKeyPair,
      myPublicKey: myPublicKey,
      transport: transport,
      useTls: useTls,
      fakeSni: fakeSni,
      nodeId: nodeId,
      chatName: chatName,
      chatAvatarBytes: chatAvatarBytes,
      isDirectMessage: isDirectMessage,
      bootstrapDirectRoom: bootstrapDirectRoom ?? this.bootstrapDirectRoom,
      directPeerPublicKeyHex:
          directPeerPublicKeyHex ?? this.directPeerPublicKeyHex,
      pingIntervalSeconds: pingIntervalSeconds,
      mediaChunkSizeBytes: mediaChunkSizeBytes,
    );
  }

  SgtpConfig copyWith({
    String? serverAddr,
    String? accountId,
    String? deviceId,
    int? discoveryPort,
    int? mediaChunkSizeBytes,
    SgtpTransportFamily? transport,
    bool? useTls,
    String? fakeSni,
    String? nodeId,
  }) {
    return SgtpConfig(
      accountId: accountId ?? this.accountId,
      deviceId: deviceId ?? this.deviceId,
      serverAddr: serverAddr ?? this.serverAddr,
      discoveryPort: discoveryPort ?? this.discoveryPort,
      roomUUID: roomUUID,
      identityKeyPair: identityKeyPair,
      myPublicKey: myPublicKey,
      transport: transport ?? this.transport,
      useTls: useTls ?? this.useTls,
      fakeSni: fakeSni ?? this.fakeSni,
      nodeId: nodeId ?? this.nodeId,
      chatName: chatName,
      chatAvatarBytes: chatAvatarBytes,
      isDirectMessage: isDirectMessage,
      bootstrapDirectRoom: bootstrapDirectRoom,
      directPeerPublicKeyHex: directPeerPublicKeyHex,
      pingIntervalSeconds: pingIntervalSeconds,
      mediaChunkSizeBytes: mediaChunkSizeBytes ?? this.mediaChunkSizeBytes,
    );
  }
}
