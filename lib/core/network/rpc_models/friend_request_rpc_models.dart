import 'dart:typed_data';

import 'package:sgtp_flutter/core/network/rpc_models/rpc_enums.dart';
import 'package:sgtp_flutter/core/network/rpc_models/rpc_request.dart';

// ── sendFriendRequest ───────────────────────────────────────────────────────

class SendFriendRequestRequest extends RpcRequest {
  final Uint8List receiverPublicKey;

  const SendFriendRequestRequest({required this.receiverPublicKey});

  @override
  String get method => 'sendFriendRequest';

  @override
  Map<String, dynamic> toMap() => {'receiverPublicKey': receiverPublicKey};
}

class SendFriendRequestResponse {
  final Uint8List requestId; // UUID bytes
  final FriendRequestStateEnum state;
  final int createdAtUs;

  const SendFriendRequestResponse({
    required this.requestId,
    required this.state,
    required this.createdAtUs,
  });

  static SendFriendRequestResponse fromMap(Map<String, dynamic> m) =>
      SendFriendRequestResponse(
        requestId: m['requestId'] as Uint8List? ?? Uint8List(16),
        state: FriendRequestStateEnum.fromValue(m['state'] is int ? m['state'] as int : 1),
        createdAtUs: parseTimestampUs(m['createdAt']),
      );
}

// ── acceptFriendRequest ─────────────────────────────────────────────────────

class AcceptFriendRequestRequest extends RpcRequest {
  final Uint8List requestId; // UUID bytes

  const AcceptFriendRequestRequest({required this.requestId});

  @override
  String get method => 'acceptFriendRequest';

  @override
  Map<String, dynamic> toMap() => {'requestId': requestId};
}

class AcceptFriendRequestResponse {
  final Uint8List friendId; // UUID bytes
  final int acceptedAtUs;

  const AcceptFriendRequestResponse({
    required this.friendId,
    required this.acceptedAtUs,
  });

  static AcceptFriendRequestResponse fromMap(Map<String, dynamic> m) =>
      AcceptFriendRequestResponse(
        friendId: m['friendId'] as Uint8List? ?? Uint8List(16),
        acceptedAtUs: parseTimestampUs(m['acceptedAt']),
      );
}

// ── declineFriendRequest ────────────────────────────────────────────────────

class DeclineFriendRequestRequest extends RpcRequest {
  final Uint8List requestId;

  const DeclineFriendRequestRequest({required this.requestId});

  @override
  String get method => 'declineFriendRequest';

  @override
  Map<String, dynamic> toMap() => {'requestId': requestId};
}

class DeclineFriendRequestResponse {
  final Uint8List requestId;
  final int declinedAtUs;

  const DeclineFriendRequestResponse({
    required this.requestId,
    required this.declinedAtUs,
  });

  static DeclineFriendRequestResponse fromMap(Map<String, dynamic> m) =>
      DeclineFriendRequestResponse(
        requestId: m['requestId'] as Uint8List? ?? Uint8List(16),
        declinedAtUs: parseTimestampUs(m['declinedAt']),
      );
}

// ── cancelFriendRequest ─────────────────────────────────────────────────────

class CancelFriendRequestRequest extends RpcRequest {
  final Uint8List requestId;

  const CancelFriendRequestRequest({required this.requestId});

  @override
  String get method => 'cancelFriendRequest';

  @override
  Map<String, dynamic> toMap() => {'requestId': requestId};
}

class CancelFriendRequestResponse {
  final int canceledAtUs;

  const CancelFriendRequestResponse({required this.canceledAtUs});

  static CancelFriendRequestResponse fromMap(Map<String, dynamic> m) =>
      CancelFriendRequestResponse(canceledAtUs: parseTimestampUs(m['canceledAt']));
}

// ── listFriendRequests ──────────────────────────────────────────────────────

class ListFriendRequestsRequest extends RpcRequest {
  final String? direction; // 'incoming' | 'outgoing' | null
  final int? limit;
  final String? cursor;

  const ListFriendRequestsRequest({this.direction, this.limit, this.cursor});

  @override
  String get method => 'listFriendRequests';

  @override
  Map<String, dynamic> toMap() => {
        if (direction != null) 'direction': direction,
        if (limit != null) 'limit': limit,
        if (cursor != null) 'cursor': cursor,
      };
}

class FriendRequestItem {
  final Uint8List requestId; // UUID bytes
  final Uint8List senderPublicKey;
  final Uint8List receiverPublicKey;
  final FriendRequestStateEnum state;

  const FriendRequestItem({
    required this.requestId,
    required this.senderPublicKey,
    required this.receiverPublicKey,
    required this.state,
  });

  static FriendRequestItem fromMap(Map<String, dynamic> m) => FriendRequestItem(
        requestId: m['requestId'] as Uint8List? ?? Uint8List(16),
        senderPublicKey: m['senderPublicKey'] as Uint8List? ?? Uint8List(32),
        receiverPublicKey:
            m['receiverPublicKey'] as Uint8List? ?? Uint8List(32),
        state: FriendRequestStateEnum.fromValue(m['state'] is int ? m['state'] as int : 1),
      );
}

class ListFriendRequestsResponse {
  final List<FriendRequestItem> items;
  final String? nextCursor;

  const ListFriendRequestsResponse({required this.items, this.nextCursor});

  static ListFriendRequestsResponse fromMap(Map<String, dynamic> m) {
    final rawItems = m['items'] as List<dynamic>? ?? [];
    return ListFriendRequestsResponse(
      items: rawItems
          .map((e) => FriendRequestItem.fromMap(e as Map<String, dynamic>))
          .toList(),
      nextCursor: m['nextCursor'] as String?,
    );
  }
}
