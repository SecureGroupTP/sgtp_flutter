import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'package:sgtp_flutter/core/constants.dart';
import 'package:sgtp_flutter/core/sgtp_transport.dart';

class SgtpConfig {
  final String? accountId;
  final String serverAddr;
  final Uint8List roomUUID;
  final SimpleKeyPairData identityKeyPair;
  final Uint8List myPublicKey;
  final Set<String> whitelist;
  final SgtpTransportFamily transport;
  final bool useTls;
  final String fakeSni;
  final String? nodeId;
  final String chatName;
  final Uint8List? chatAvatarBytes;
  final int pingIntervalSeconds;
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
    this.fakeSni = '',
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
        fakeSni: fakeSni,
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
        fakeSni: fakeSni,
        nodeId: nodeId,
        chatName: name ?? chatName,
        chatAvatarBytes: avatar ?? chatAvatarBytes,
        pingIntervalSeconds: pingIntervalSeconds,
        mediaChunkSizeBytes: mediaChunkSizeBytes,
      );

  SgtpConfig copyWith({
    Set<String>? whitelist,
    String? serverAddr,
    String? accountId,
    int? mediaChunkSizeBytes,
    SgtpTransportFamily? transport,
    bool? useTls,
    String? fakeSni,
    String? nodeId,
  }) {
    return SgtpConfig(
      accountId: accountId ?? this.accountId,
      serverAddr: serverAddr ?? this.serverAddr,
      roomUUID: roomUUID,
      identityKeyPair: identityKeyPair,
      myPublicKey: myPublicKey,
      whitelist: whitelist ?? this.whitelist,
      transport: transport ?? this.transport,
      useTls: useTls ?? this.useTls,
      fakeSni: fakeSni ?? this.fakeSni,
      nodeId: nodeId ?? this.nodeId,
      chatName: chatName,
      chatAvatarBytes: chatAvatarBytes,
      pingIntervalSeconds: pingIntervalSeconds,
      mediaChunkSizeBytes: mediaChunkSizeBytes ?? this.mediaChunkSizeBytes,
    );
  }
}
