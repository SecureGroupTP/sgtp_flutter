import 'dart:typed_data';

import 'package:sgtp_flutter/core/network/rpc_models/rpc_request.dart';
import 'package:sgtp_flutter/core/uuid_v7.dart';

class CreateChatRoomRequest extends RpcRequest {
  final String? title;
  final String? description;
  final int visibility;

  const CreateChatRoomRequest({
    this.title,
    this.description,
    required this.visibility,
  });

  @override
  String get method => 'createChatRoom';

  @override
  Map<String, dynamic> toMap() => {
        if (title != null) 'title': title,
        if (description != null) 'description': description,
        'visibility': visibility,
      };
}

class CreateChatRoomResponse {
  final String roomId;
  final int createdAtUs;

  const CreateChatRoomResponse({
    required this.roomId,
    required this.createdAtUs,
  });

  static CreateChatRoomResponse fromMap(Map<String, dynamic> m) =>
      CreateChatRoomResponse(
        roomId: _uuidToString(m['roomId']),
        createdAtUs: parseTimestampUs(m['createdAt']),
      );
}

class GetChatRoomRequest extends RpcRequest {
  final String roomId;

  const GetChatRoomRequest({required this.roomId});

  @override
  String get method => 'getChatRoom';

  @override
  Map<String, dynamic> toMap() => {'roomId': roomId};
}

class ChatRoomData {
  final String roomId;
  final String title;
  final String? description;
  final int visibility;

  const ChatRoomData({
    required this.roomId,
    required this.title,
    required this.description,
    required this.visibility,
  });

  static ChatRoomData fromMap(Map<String, dynamic> m) => ChatRoomData(
        roomId: _uuidToString(m['roomId']),
        title: (m['title'] as String?) ?? '',
        description: m['description'] as String?,
        visibility: (m['visibility'] as num?)?.toInt() ?? 0,
      );
}

class GetChatRoomResponse {
  final ChatRoomData room;

  const GetChatRoomResponse({required this.room});

  static GetChatRoomResponse fromMap(Map<String, dynamic> m) =>
      GetChatRoomResponse(
        room: ChatRoomData.fromMap(
          (m['room'] as Map).map((key, value) => MapEntry('$key', value)),
        ),
      );
}

class SendChatInvitationRequest extends RpcRequest {
  final String roomId;
  final Uint8List inviteePublicKey;

  const SendChatInvitationRequest({
    required this.roomId,
    required this.inviteePublicKey,
  });

  @override
  String get method => 'sendChatInvitation';

  @override
  Map<String, dynamic> toMap() => {
        'roomId': roomId,
        'inviteePublicKey': inviteePublicKey,
      };
}

class SendChatInvitationResponse {
  final String invitationId;
  final int createdAtUs;

  const SendChatInvitationResponse({
    required this.invitationId,
    required this.createdAtUs,
  });

  static SendChatInvitationResponse fromMap(Map<String, dynamic> m) =>
      SendChatInvitationResponse(
        invitationId: _uuidToString(m['invitationId']),
        createdAtUs: parseTimestampUs(m['createdAt']),
      );
}

class ListIncomingChatInvitationsRequest extends RpcRequest {
  final int? limit;
  final String? cursor;

  const ListIncomingChatInvitationsRequest({this.limit, this.cursor});

  @override
  String get method => 'listIncomingChatInvitations';

  @override
  Map<String, dynamic> toMap() => {
        if (limit != null) 'limit': limit,
        if (cursor != null) 'cursor': cursor,
      };
}

class IncomingChatInvitationItem {
  final String invitationId;
  final String roomId;
  final Uint8List inviterPublicKey;
  final Uint8List inviteePublicKey;
  final int state;
  final int createdAtUs;

  const IncomingChatInvitationItem({
    required this.invitationId,
    required this.roomId,
    required this.inviterPublicKey,
    required this.inviteePublicKey,
    required this.state,
    required this.createdAtUs,
  });

  static IncomingChatInvitationItem fromMap(Map<String, dynamic> m) =>
      IncomingChatInvitationItem(
        invitationId: _uuidToString(m['invitationId']),
        roomId: _uuidToString(m['roomId']),
        inviterPublicKey: m['inviterPublicKey'] as Uint8List,
        inviteePublicKey: m['inviteePublicKey'] as Uint8List,
        state: (m['state'] as num?)?.toInt() ?? 0,
        createdAtUs: parseTimestampUs(m['createdAt']),
      );
}

class ListIncomingChatInvitationsResponse {
  final List<IncomingChatInvitationItem> items;
  final String? nextCursor;

  const ListIncomingChatInvitationsResponse({
    required this.items,
    this.nextCursor,
  });

  static ListIncomingChatInvitationsResponse fromMap(Map<String, dynamic> m) {
    final raw = (m['items'] as List?) ?? const [];
    return ListIncomingChatInvitationsResponse(
      items: raw
          .whereType<Map>()
          .map((item) => IncomingChatInvitationItem.fromMap(
              item.map((key, value) => MapEntry('$key', value))))
          .toList(),
      nextCursor: m['nextCursor'] as String?,
    );
  }
}

class AcceptChatInvitationRequest extends RpcRequest {
  final String invitationId;

  const AcceptChatInvitationRequest({required this.invitationId});

  @override
  String get method => 'acceptChatInvitation';

  @override
  Map<String, dynamic> toMap() => {'invitationId': invitationId};
}

class AcceptChatInvitationResponse {
  final String roomId;
  final int acceptedAtUs;

  const AcceptChatInvitationResponse({
    required this.roomId,
    required this.acceptedAtUs,
  });

  static AcceptChatInvitationResponse fromMap(Map<String, dynamic> m) =>
      AcceptChatInvitationResponse(
        roomId: _uuidToString(m['roomId']),
        acceptedAtUs: parseTimestampUs(m['acceptedAt']),
      );
}

class UpdateChatRoomStateRequest extends RpcRequest {
  final String roomId;
  final String groupId;
  final int epoch;
  final Uint8List treeBytes;
  final Uint8List treeHash;

  const UpdateChatRoomStateRequest({
    required this.roomId,
    required this.groupId,
    required this.epoch,
    required this.treeBytes,
    required this.treeHash,
  });

  @override
  String get method => 'updateChatRoomState';

  @override
  Map<String, dynamic> toMap() => {
        'roomId': roomId,
        'groupId': groupId,
        'epoch': epoch,
        'treeBytes': treeBytes,
        'treeHash': treeHash,
      };
}

class UpdateChatRoomStateResponse {
  final int acceptedAtUs;

  const UpdateChatRoomStateResponse({required this.acceptedAtUs});

  static UpdateChatRoomStateResponse fromMap(Map<String, dynamic> m) =>
      UpdateChatRoomStateResponse(
        acceptedAtUs: parseTimestampUs(m['acceptedAt']),
      );
}

String _uuidToString(Object? value) {
  if (value is String) return value;
  if (value is Uint8List) return uuidBytesToHex(value);
  return '';
}
