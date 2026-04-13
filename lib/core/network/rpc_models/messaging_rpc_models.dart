import 'dart:typed_data';

import 'package:sgtp_flutter/core/network/rpc_models/rpc_request.dart';
import 'package:sgtp_flutter/core/uuid_v7.dart';

class SendMessageRequest extends RpcRequest {
  final String roomId;
  final Uint8List clientMsgId;
  final List<Uint8List> body;

  const SendMessageRequest({
    required this.roomId,
    required this.clientMsgId,
    required this.body,
  });

  @override
  String get method => 'sendMessage';

  @override
  Map<String, dynamic> toMap() => {
        'roomId': roomId,
        'clientMsgId': clientMsgId,
        'body': body,
      };
}

class SendMessageResponse {
  final String messageId;
  final int createdAtUs;

  const SendMessageResponse({
    required this.messageId,
    required this.createdAtUs,
  });

  static SendMessageResponse fromMap(Map<String, dynamic> m) =>
      SendMessageResponse(
        messageId: _uuidToString(m['messageId']),
        createdAtUs: parseTimestampUs(m['createdAt']),
      );
}

class DeleteMessageRequest extends RpcRequest {
  final String roomId;
  final String messageId;

  const DeleteMessageRequest({
    required this.roomId,
    required this.messageId,
  });

  @override
  String get method => 'deleteMessage';

  @override
  Map<String, dynamic> toMap() => {
        'roomId': roomId,
        'messageId': messageId,
      };
}

class DeleteMessageResponse {
  final int deletedAtUs;

  const DeleteMessageResponse({required this.deletedAtUs});

  static DeleteMessageResponse fromMap(Map<String, dynamic> m) =>
      DeleteMessageResponse(
        deletedAtUs: parseTimestampUs(m['deletedAt']),
      );
}

class MlsMessageReceivedEvent {
  final String roomId;
  final String messageId;
  final Uint8List senderPublicKey;
  final List<Uint8List> body;

  const MlsMessageReceivedEvent({
    required this.roomId,
    required this.messageId,
    required this.senderPublicKey,
    required this.body,
  });

  static MlsMessageReceivedEvent fromParameters(Map<String, dynamic> m) {
    final rawBody = (m['body'] as List?) ?? const [];
    return MlsMessageReceivedEvent(
      roomId: (m['roomId'] as String?) ?? '',
      messageId: _uuidToString(m['messageId']),
      senderPublicKey: m['senderPublicKey'] as Uint8List,
      body: rawBody.whereType<Uint8List>().toList(),
    );
  }
}

String _uuidToString(Object? value) {
  if (value is String) return value;
  if (value is Uint8List) return uuidBytesToHex(value);
  return '';
}
