import 'dart:typed_data';

import 'package:sgtp_flutter/core/network/events/event_decode.dart';
import 'package:sgtp_flutter/core/network/events/sgtp_server_event.dart';
import 'package:sgtp_flutter/core/uuid_v7.dart';

class MlsMessageReceivedNetworkEvent extends SgtpServerEvent {
  const MlsMessageReceivedNetworkEvent({
    required this.roomId,
    required this.messageId,
    required this.senderPublicKey,
    required this.body,
  });

  final String roomId;
  final String messageId;
  final Uint8List senderPublicKey;
  final List<Uint8List> body;

  factory MlsMessageReceivedNetworkEvent.fromParameters(
    Map<String, dynamic> parameters,
  ) {
    final rawBody = (parameters['body'] as List?) ?? const [];
    return MlsMessageReceivedNetworkEvent(
      roomId: (parameters['roomId'] as String?) ?? '',
      messageId: _uuidToString(parameters['messageId']),
      senderPublicKey: decodeEventBytes(parameters['senderPublicKey']),
      body: rawBody.map(decodeEventBytes).toList(growable: false),
    );
  }

  @override
  String get type => 'mlsMessageReceived';
}

String _uuidToString(Object? value) {
  if (value is String) return value;
  if (value is Uint8List) return uuidBytesToHex(value);
  return '';
}
