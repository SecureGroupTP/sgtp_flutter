import 'dart:typed_data';

import 'package:sgtp_flutter/core/network/rpc_models/rpc_request.dart';
import 'package:sgtp_flutter/core/uuid_v7.dart';

class ChatRoomListItem {
  final String roomId;
  final String title;
  final int updatedAtUs;

  const ChatRoomListItem({
    required this.roomId,
    required this.title,
    required this.updatedAtUs,
  });

  static ChatRoomListItem fromMap(Map<String, dynamic> m) => ChatRoomListItem(
        roomId: _uuidToString(m['roomId']),
        title: m['title'] as String? ?? '',
        updatedAtUs: parseTimestampUs(m['updatedAt']),
      );
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
        title: m['title'] as String? ?? '',
        description: m['description'] as String?,
        visibility: (m['visibility'] as num?)?.toInt() ?? 0,
      );
}

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

class CreateDirectRoomRequest extends RpcRequest {
  final Uint8List targetUserPublicKey;

  const CreateDirectRoomRequest({
    required this.targetUserPublicKey,
  });

  @override
  String get method => 'createDirectRoom';

  @override
  Map<String, dynamic> toMap() => {
        'targetUserPublicKey': targetUserPublicKey,
      };
}

class CreateDirectRoomResponse {
  final String roomId;
  final bool alreadyExisted;
  final int createdAtUs;

  const CreateDirectRoomResponse({
    required this.roomId,
    required this.alreadyExisted,
    required this.createdAtUs,
  });

  static CreateDirectRoomResponse fromMap(Map<String, dynamic> m) =>
      CreateDirectRoomResponse(
        roomId: _uuidToString(m['roomId']),
        alreadyExisted: m['alreadyExisted'] as bool? ?? false,
        createdAtUs: parseTimestampUs(m['createdAt']),
      );
}

class ListChatRoomsRequest extends RpcRequest {
  final int? limit;
  final String? cursor;

  const ListChatRoomsRequest({this.limit, this.cursor});

  @override
  String get method => 'listChatRooms';

  @override
  Map<String, dynamic> toMap() => {
        if (limit != null) 'limit': limit,
        if (cursor != null) 'cursor': cursor,
      };
}

class ListChatRoomsResponse {
  final List<ChatRoomListItem> items;
  final String? nextCursor;

  const ListChatRoomsResponse({
    required this.items,
    this.nextCursor,
  });

  static ListChatRoomsResponse fromMap(Map<String, dynamic> m) {
    final raw = (m['items'] as List?) ?? const [];
    return ListChatRoomsResponse(
      items: raw
          .whereType<Map>()
          .map((item) => ChatRoomListItem.fromMap(_map(item)))
          .toList(),
      nextCursor: m['nextCursor'] as String?,
    );
  }
}

class GetChatRoomRequest extends RpcRequest {
  final String roomId;

  const GetChatRoomRequest({required this.roomId});

  @override
  String get method => 'getChatRoom';

  @override
  Map<String, dynamic> toMap() => {'roomId': roomId};
}

class GetChatRoomResponse {
  final ChatRoomData room;

  const GetChatRoomResponse({required this.room});

  static GetChatRoomResponse fromMap(Map<String, dynamic> m) =>
      GetChatRoomResponse(
        room: ChatRoomData.fromMap(_map(m['room'])),
      );
}

class SearchChatRoomsRequest extends RpcRequest {
  final String query;
  final int? limit;
  final String? cursor;

  const SearchChatRoomsRequest({
    required this.query,
    this.limit,
    this.cursor,
  });

  @override
  String get method => 'searchChatRooms';

  @override
  Map<String, dynamic> toMap() => {
        'query': query,
        if (limit != null) 'limit': limit,
        if (cursor != null) 'cursor': cursor,
      };
}

class SearchChatRoomsResponse {
  final List<ChatRoomListItem> items;
  final String? nextCursor;

  const SearchChatRoomsResponse({
    required this.items,
    this.nextCursor,
  });

  static SearchChatRoomsResponse fromMap(Map<String, dynamic> m) {
    final raw = (m['items'] as List?) ?? const [];
    return SearchChatRoomsResponse(
      items: raw
          .whereType<Map>()
          .map((item) => ChatRoomListItem.fromMap(_map(item)))
          .toList(),
      nextCursor: m['nextCursor'] as String?,
    );
  }
}

class SyncChatRoomRequest extends RpcRequest {
  final String roomId;
  final int? lastSyncAtUs;

  const SyncChatRoomRequest({
    required this.roomId,
    this.lastSyncAtUs,
  });

  @override
  String get method => 'syncChatRoom';

  @override
  Map<String, dynamic> toMap() => {
        'roomId': roomId,
        if (lastSyncAtUs != null) 'lastSyncAt': lastSyncAtUs,
      };
}

class SyncChatRoomResponse {
  final ChatRoomData room;
  final int syncedAtUs;

  const SyncChatRoomResponse({
    required this.room,
    required this.syncedAtUs,
  });

  static SyncChatRoomResponse fromMap(Map<String, dynamic> m) =>
      SyncChatRoomResponse(
        room: ChatRoomData.fromMap(_map(m['room'])),
        syncedAtUs: parseTimestampUs(m['syncedAt']),
      );
}

class UpdateChatRoomRequest extends RpcRequest {
  final String roomId;
  final String? title;
  final String? description;
  final String? avatarHash;

  const UpdateChatRoomRequest({
    required this.roomId,
    this.title,
    this.description,
    this.avatarHash,
  });

  @override
  String get method => 'updateChatRoom';

  @override
  Map<String, dynamic> toMap() => {
        'roomId': roomId,
        if (title != null) 'title': title,
        if (description != null) 'description': description,
        if (avatarHash != null) 'avatarHash': avatarHash,
      };
}

class UpdateChatRoomResponse {
  final int updatedAtUs;

  const UpdateChatRoomResponse({required this.updatedAtUs});

  static UpdateChatRoomResponse fromMap(Map<String, dynamic> m) =>
      UpdateChatRoomResponse(
        updatedAtUs: parseTimestampUs(m['updatedAt']),
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

class FetchChatRoomStateRequest extends RpcRequest {
  final String roomId;
  final int epoch;

  const FetchChatRoomStateRequest({
    required this.roomId,
    required this.epoch,
  });

  @override
  String get method => 'fetchChatRoomState';

  @override
  Map<String, dynamic> toMap() => {
        'roomId': roomId,
        'epoch': epoch,
      };
}

class FetchChatRoomStateResponse {
  final String groupId;
  final int epoch;
  final Uint8List treeBytes;
  final Uint8List treeHash;

  const FetchChatRoomStateResponse({
    required this.groupId,
    required this.epoch,
    required this.treeBytes,
    required this.treeHash,
  });

  static FetchChatRoomStateResponse fromMap(Map<String, dynamic> m) =>
      FetchChatRoomStateResponse(
        groupId: _uuidToString(m['groupId']),
        epoch: (m['epoch'] as num?)?.toInt() ?? 0,
        treeBytes: _decodeBytes(m['treeBytes']),
        treeHash: _decodeBytes(m['treeHash']),
      );
}

class DeleteChatRoomRequest extends RpcRequest {
  final String roomId;

  const DeleteChatRoomRequest({required this.roomId});

  @override
  String get method => 'deleteChatRoom';

  @override
  Map<String, dynamic> toMap() => {'roomId': roomId};
}

class DeleteChatRoomResponse {
  final int deletedAtUs;

  const DeleteChatRoomResponse({required this.deletedAtUs});

  static DeleteChatRoomResponse fromMap(Map<String, dynamic> m) =>
      DeleteChatRoomResponse(
        deletedAtUs: parseTimestampUs(m['deletedAt']),
      );
}

class GetChatRoomAvatarRequest extends RpcRequest {
  final String roomId;

  const GetChatRoomAvatarRequest({required this.roomId});

  @override
  String get method => 'getChatRoomAvatar';

  @override
  Map<String, dynamic> toMap() => {'roomId': roomId};
}

class GetChatRoomAvatarResponse {
  final Uint8List avatarBytes;
  final String contentType;

  const GetChatRoomAvatarResponse({
    required this.avatarBytes,
    required this.contentType,
  });

  static GetChatRoomAvatarResponse fromMap(Map<String, dynamic> m) =>
      GetChatRoomAvatarResponse(
        avatarBytes: _decodeBytes(m['avatarBytes']),
        contentType: m['contentType'] as String? ?? 'application/octet-stream',
      );
}

class LeaveChatRoomRequest extends RpcRequest {
  final String roomId;

  const LeaveChatRoomRequest({required this.roomId});

  @override
  String get method => 'leaveChatRoom';

  @override
  Map<String, dynamic> toMap() => {'roomId': roomId};
}

class LeaveChatRoomResponse {
  final int leftAtUs;

  const LeaveChatRoomResponse({required this.leftAtUs});

  static LeaveChatRoomResponse fromMap(Map<String, dynamic> m) =>
      LeaveChatRoomResponse(
        leftAtUs: parseTimestampUs(m['leftAt']),
      );
}

class KickChatMemberRequest extends RpcRequest {
  final String roomId;
  final Uint8List userPublicKey;

  const KickChatMemberRequest({
    required this.roomId,
    required this.userPublicKey,
  });

  @override
  String get method => 'kickChatMember';

  @override
  Map<String, dynamic> toMap() => {
        'roomId': roomId,
        'userPublicKey': userPublicKey,
      };
}

class KickChatMemberResponse {
  final int kickedAtUs;

  const KickChatMemberResponse({required this.kickedAtUs});

  static KickChatMemberResponse fromMap(Map<String, dynamic> m) =>
      KickChatMemberResponse(
        kickedAtUs: parseTimestampUs(m['kickedAt']),
      );
}

class ChatMemberItem {
  final Uint8List userPublicKey;
  final int role;
  final int joinedAtUs;

  const ChatMemberItem({
    required this.userPublicKey,
    required this.role,
    required this.joinedAtUs,
  });

  static ChatMemberItem fromMap(Map<String, dynamic> m) => ChatMemberItem(
        userPublicKey: _decodeBytes(m['userPublicKey']),
        role: (m['role'] as num?)?.toInt() ?? 0,
        joinedAtUs: parseTimestampUs(m['joinedAt']),
      );
}

class ListChatMembersRequest extends RpcRequest {
  final String roomId;
  final int? limit;
  final String? cursor;

  const ListChatMembersRequest({
    required this.roomId,
    this.limit,
    this.cursor,
  });

  @override
  String get method => 'listChatMembers';

  @override
  Map<String, dynamic> toMap() => {
        'roomId': roomId,
        if (limit != null) 'limit': limit,
        if (cursor != null) 'cursor': cursor,
      };
}

class ListChatMembersResponse {
  final List<ChatMemberItem> items;
  final String? nextCursor;
  final int? totalCount;

  const ListChatMembersResponse({
    required this.items,
    this.nextCursor,
    this.totalCount,
  });

  static ListChatMembersResponse fromMap(Map<String, dynamic> m) {
    final raw = (m['items'] as List?) ?? const [];
    return ListChatMembersResponse(
      items: raw
          .whereType<Map>()
          .map((item) => ChatMemberItem.fromMap(_map(item)))
          .toList(),
      nextCursor: m['nextCursor'] as String?,
      totalCount: (m['totalCount'] as num?)?.toInt(),
    );
  }
}

class UpdateChatMemberRoleRequest extends RpcRequest {
  final String roomId;
  final Uint8List userPublicKey;
  final int role;

  const UpdateChatMemberRoleRequest({
    required this.roomId,
    required this.userPublicKey,
    required this.role,
  });

  @override
  String get method => 'updateChatMemberRole';

  @override
  Map<String, dynamic> toMap() => {
        'roomId': roomId,
        'userPublicKey': userPublicKey,
        'role': role,
      };
}

class UpdateChatMemberRoleResponse {
  final int updatedAtUs;

  const UpdateChatMemberRoleResponse({required this.updatedAtUs});

  static UpdateChatMemberRoleResponse fromMap(Map<String, dynamic> m) =>
      UpdateChatMemberRoleResponse(
        updatedAtUs: parseTimestampUs(m['updatedAt']),
      );
}

class ChatMemberPermissionItem {
  final String id;
  final String roomId;
  final Uint8List userPublicKey;
  final String permissionKey;
  final bool isAllowed;
  final int createdAtUs;

  const ChatMemberPermissionItem({
    required this.id,
    required this.roomId,
    required this.userPublicKey,
    required this.permissionKey,
    required this.isAllowed,
    required this.createdAtUs,
  });

  static ChatMemberPermissionItem fromMap(Map<String, dynamic> m) =>
      ChatMemberPermissionItem(
        id: _uuidToString(m['id']),
        roomId: _uuidToString(m['roomId']),
        userPublicKey: _decodeBytes(m['userPublicKey']),
        permissionKey: m['permissionKey'] as String? ?? '',
        isAllowed: (m['isAllowed'] as bool?) ?? false,
        createdAtUs: parseTimestampUs(m['createdAt']),
      );
}

class CreateChatMemberPermissionRequest extends RpcRequest {
  final String roomId;
  final Uint8List userPublicKey;
  final String permissionKey;
  final bool isAllowed;

  const CreateChatMemberPermissionRequest({
    required this.roomId,
    required this.userPublicKey,
    required this.permissionKey,
    required this.isAllowed,
  });

  @override
  String get method => 'createChatMemberPermission';

  @override
  Map<String, dynamic> toMap() => {
        'roomId': roomId,
        'userPublicKey': userPublicKey,
        'permissionKey': permissionKey,
        'isAllowed': isAllowed,
      };
}

class CreateChatMemberPermissionResponse {
  final String id;
  final int createdAtUs;

  const CreateChatMemberPermissionResponse({
    required this.id,
    required this.createdAtUs,
  });

  static CreateChatMemberPermissionResponse fromMap(Map<String, dynamic> m) =>
      CreateChatMemberPermissionResponse(
        id: _uuidToString(m['id']),
        createdAtUs: parseTimestampUs(m['createdAt']),
      );
}

class ListChatMemberPermissionsRequest extends RpcRequest {
  final String roomId;
  final Uint8List? userPublicKey;
  final int? limit;
  final String? cursor;

  const ListChatMemberPermissionsRequest({
    required this.roomId,
    this.userPublicKey,
    this.limit,
    this.cursor,
  });

  @override
  String get method => 'listChatMemberPermissions';

  @override
  Map<String, dynamic> toMap() => {
        'roomId': roomId,
        if (userPublicKey != null) 'userPublicKey': userPublicKey,
        if (limit != null) 'limit': limit,
        if (cursor != null) 'cursor': cursor,
      };
}

class ListChatMemberPermissionsResponse {
  final List<ChatMemberPermissionItem> items;
  final String? nextCursor;

  const ListChatMemberPermissionsResponse({
    required this.items,
    this.nextCursor,
  });

  static ListChatMemberPermissionsResponse fromMap(Map<String, dynamic> m) {
    final raw = (m['items'] as List?) ?? const [];
    return ListChatMemberPermissionsResponse(
      items: raw
          .whereType<Map>()
          .map((item) => ChatMemberPermissionItem.fromMap(_map(item)))
          .toList(),
      nextCursor: m['nextCursor'] as String?,
    );
  }
}

class UpdateChatMemberPermissionRequest extends RpcRequest {
  final String permissionId;
  final bool isAllowed;

  const UpdateChatMemberPermissionRequest({
    required this.permissionId,
    required this.isAllowed,
  });

  @override
  String get method => 'updateChatMemberPermission';

  @override
  Map<String, dynamic> toMap() => {
        'permissionId': permissionId,
        'isAllowed': isAllowed,
      };
}

class UpdateChatMemberPermissionResponse {
  final int updatedAtUs;

  const UpdateChatMemberPermissionResponse({required this.updatedAtUs});

  static UpdateChatMemberPermissionResponse fromMap(Map<String, dynamic> m) =>
      UpdateChatMemberPermissionResponse(
        updatedAtUs: parseTimestampUs(m['updatedAt']),
      );
}

class DeleteChatMemberPermissionRequest extends RpcRequest {
  final String permissionId;

  const DeleteChatMemberPermissionRequest({required this.permissionId});

  @override
  String get method => 'deleteChatMemberPermission';

  @override
  Map<String, dynamic> toMap() => {'permissionId': permissionId};
}

class DeleteChatMemberPermissionResponse {
  final int deletedAtUs;

  const DeleteChatMemberPermissionResponse({required this.deletedAtUs});

  static DeleteChatMemberPermissionResponse fromMap(Map<String, dynamic> m) =>
      DeleteChatMemberPermissionResponse(
        deletedAtUs: parseTimestampUs(m['deletedAt']),
      );
}

class ChatInvitationItem {
  final String invitationId;
  final String roomId;
  final Uint8List inviterPublicKey;
  final Uint8List inviteePublicKey;
  final int? expiresAtUs;
  final Uint8List inviteToken;
  final Uint8List inviteTokenSignature;
  final int state;
  final int createdAtUs;

  const ChatInvitationItem({
    required this.invitationId,
    required this.roomId,
    required this.inviterPublicKey,
    required this.inviteePublicKey,
    required this.expiresAtUs,
    required this.inviteToken,
    required this.inviteTokenSignature,
    required this.state,
    required this.createdAtUs,
  });

  static ChatInvitationItem fromMap(Map<String, dynamic> m) =>
      ChatInvitationItem(
        invitationId: _uuidToString(m['invitationId']),
        roomId: _uuidToString(m['roomId']),
        inviterPublicKey: _decodeBytes(m['inviterPublicKey']),
        inviteePublicKey: _decodeBytes(m['inviteePublicKey']),
        expiresAtUs:
            m['expiresAt'] == null ? null : parseTimestampUs(m['expiresAt']),
        inviteToken: _decodeBytes(m['inviteToken']),
        inviteTokenSignature: _decodeBytes(m['inviteTokenSignature']),
        state: (m['state'] as num?)?.toInt() ?? 0,
        createdAtUs: parseTimestampUs(m['createdAt']),
      );
}

class SendChatInvitationRequest extends RpcRequest {
  final String roomId;
  final Uint8List inviteePublicKey;
  final int? expiresAtUs;
  final Uint8List? inviteToken;
  final Uint8List? inviteTokenSignature;

  const SendChatInvitationRequest({
    required this.roomId,
    required this.inviteePublicKey,
    this.expiresAtUs,
    this.inviteToken,
    this.inviteTokenSignature,
  });

  @override
  String get method => 'sendChatInvitation';

  @override
  Map<String, dynamic> toMap() => {
        'roomId': roomId,
        'inviteePublicKey': inviteePublicKey,
        if (expiresAtUs != null) 'expiresAt': expiresAtUs,
        if (inviteToken != null) 'inviteToken': inviteToken,
        if (inviteTokenSignature != null)
          'inviteTokenSignature': inviteTokenSignature,
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

class RevokeChatInvitationRequest extends RpcRequest {
  final String invitationId;

  const RevokeChatInvitationRequest({required this.invitationId});

  @override
  String get method => 'revokeChatInvitation';

  @override
  Map<String, dynamic> toMap() => {'invitationId': invitationId};
}

class RevokeChatInvitationResponse {
  final int revokedAtUs;

  const RevokeChatInvitationResponse({required this.revokedAtUs});

  static RevokeChatInvitationResponse fromMap(Map<String, dynamic> m) =>
      RevokeChatInvitationResponse(
        revokedAtUs: parseTimestampUs(m['revokedAt']),
      );
}

class ListSentChatInvitationsRequest extends RpcRequest {
  final String? roomId;
  final int? limit;
  final String? cursor;

  const ListSentChatInvitationsRequest({
    this.roomId,
    this.limit,
    this.cursor,
  });

  @override
  String get method => 'listSentChatInvitations';

  @override
  Map<String, dynamic> toMap() => {
        if (roomId != null) 'roomId': roomId,
        if (limit != null) 'limit': limit,
        if (cursor != null) 'cursor': cursor,
      };
}

class ListSentChatInvitationsResponse {
  final List<ChatInvitationItem> items;
  final String? nextCursor;

  const ListSentChatInvitationsResponse({
    required this.items,
    this.nextCursor,
  });

  static ListSentChatInvitationsResponse fromMap(Map<String, dynamic> m) {
    final raw = (m['items'] as List?) ?? const [];
    return ListSentChatInvitationsResponse(
      items: raw
          .whereType<Map>()
          .map((item) => ChatInvitationItem.fromMap(_map(item)))
          .toList(),
      nextCursor: m['nextCursor'] as String?,
    );
  }
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

class ListIncomingChatInvitationsResponse {
  final List<ChatInvitationItem> items;
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
          .map((item) => ChatInvitationItem.fromMap(_map(item)))
          .toList(),
      nextCursor: m['nextCursor'] as String?,
    );
  }
}

class AcceptChatInvitationRequest extends RpcRequest {
  final String invitationId;
  final Uint8List? commitBytes;

  const AcceptChatInvitationRequest({
    required this.invitationId,
    this.commitBytes,
  });

  @override
  String get method => 'acceptChatInvitation';

  @override
  Map<String, dynamic> toMap() => {
        'invitationId': invitationId,
        if (commitBytes != null) 'commitBytes': commitBytes,
      };
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

class DeclineChatInvitationRequest extends RpcRequest {
  final String invitationId;

  const DeclineChatInvitationRequest({required this.invitationId});

  @override
  String get method => 'declineChatInvitation';

  @override
  Map<String, dynamic> toMap() => {'invitationId': invitationId};
}

class DeclineChatInvitationResponse {
  final int declinedAtUs;

  const DeclineChatInvitationResponse({required this.declinedAtUs});

  static DeclineChatInvitationResponse fromMap(Map<String, dynamic> m) =>
      DeclineChatInvitationResponse(
        declinedAtUs: parseTimestampUs(m['declinedAt']),
      );
}

Map<String, dynamic> _map(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) {
    return value.map((key, item) => MapEntry('$key', item));
  }
  return const {};
}

Uint8List _decodeBytes(Object? value) {
  if (value is Uint8List) return value;
  if (value is List<int>) return Uint8List.fromList(value);
  return Uint8List(0);
}

String _uuidToString(Object? value) {
  if (value is String) return value;
  if (value is Uint8List) return uuidBytesToHex(value);
  return '';
}
