import 'dart:typed_data';

// ── listFriends ─────────────────────────────────────────────────────────────

class ListFriendsRequest {
  final int? limit;
  final String? cursor;

  const ListFriendsRequest({this.limit, this.cursor});

  Map<String, dynamic> toMap() => {
        if (limit != null) 'limit': limit,
        if (cursor != null) 'cursor': cursor,
      };
}

class FriendItem {
  /// UUID bytes (16 bytes) — ID of the friendship record.
  final Uint8List id;
  final Uint8List friendPublicKey;
  final int acceptedAtUs; // microseconds since epoch

  const FriendItem({
    required this.id,
    required this.friendPublicKey,
    required this.acceptedAtUs,
  });

  static FriendItem fromMap(Map<String, dynamic> m) => FriendItem(
        id: m['id'] as Uint8List? ?? Uint8List(16),
        friendPublicKey: m['friendId'] as Uint8List? ?? Uint8List(32),
        acceptedAtUs: (m['acceptedAt'] as int?) ?? 0,
      );
}

class ListFriendsResponse {
  final List<FriendItem> items;
  final String? nextCursor;
  final int? totalCount;

  const ListFriendsResponse({
    required this.items,
    this.nextCursor,
    this.totalCount,
  });

  static ListFriendsResponse fromMap(Map<String, dynamic> m) {
    final rawItems = m['items'] as List<dynamic>? ?? [];
    return ListFriendsResponse(
      items: rawItems
          .map((e) => FriendItem.fromMap(e as Map<String, dynamic>))
          .toList(),
      nextCursor: m['nextCursor'] as String?,
      totalCount: m['totalCount'] as int?,
    );
  }
}

// ── removeFriend ────────────────────────────────────────────────────────────

class RemoveFriendRequest {
  final Uint8List friendPublicKey;

  const RemoveFriendRequest({required this.friendPublicKey});

  Map<String, dynamic> toMap() => {'friendPublicKey': friendPublicKey};
}

class RemoveFriendResponse {
  final int removedAtUs;

  const RemoveFriendResponse({required this.removedAtUs});

  static RemoveFriendResponse fromMap(Map<String, dynamic> m) =>
      RemoveFriendResponse(removedAtUs: (m['removedAt'] as int?) ?? 0);
}
