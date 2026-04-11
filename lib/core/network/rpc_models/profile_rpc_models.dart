import 'dart:typed_data';

import 'package:sgtp_flutter/core/network/rpc_models/rpc_request.dart';

// ── getProfile ──────────────────────────────────────────────────────────────

class GetProfileRequest extends RpcRequest {
  final Uint8List userPublicKey;

  const GetProfileRequest({required this.userPublicKey});

  @override
  String get method => 'getProfile';

  @override
  Map<String, dynamic> toMap() => {'userPublicKey': userPublicKey};
}

class ProfileData {
  final Uint8List publicKey;
  final String username;
  final String? displayName;
  final String? bio;
  final int lastSeenAtUs; // microseconds since epoch

  const ProfileData({
    required this.publicKey,
    required this.username,
    this.displayName,
    this.bio,
    required this.lastSeenAtUs,
  });

  static ProfileData fromMap(Map<String, dynamic> m) => ProfileData(
        publicKey: m['publicKey'] as Uint8List,
        username: m['username'] as String? ?? '',
        displayName: m['displayName'] as String?,
        bio: m['bio'] as String?,
        lastSeenAtUs: (m['lastSeenAt'] as int?) ?? 0,
      );
}

class GetProfileResponse {
  final ProfileData profile;

  const GetProfileResponse({required this.profile});

  static GetProfileResponse fromMap(Map<String, dynamic> m) =>
      GetProfileResponse(
        profile: ProfileData.fromMap(m['profile'] as Map<String, dynamic>),
      );
}

// ── updateProfile ───────────────────────────────────────────────────────────

class UpdateProfileRequest extends RpcRequest {
  final String? username;
  final String? displayName;
  final String? avatarHash;
  final String? bio;

  const UpdateProfileRequest({
    this.username,
    this.displayName,
    this.avatarHash,
    this.bio,
  });

  @override
  String get method => 'updateProfile';

  @override
  Map<String, dynamic> toMap() => {
        if (username != null) 'username': username,
        if (displayName != null) 'displayName': displayName,
        if (avatarHash != null) 'avatarHash': avatarHash,
        if (bio != null) 'bio': bio,
      };
}

class UpdateProfileResponse {
  final int updatedAtUs;

  const UpdateProfileResponse({required this.updatedAtUs});

  static UpdateProfileResponse fromMap(Map<String, dynamic> m) =>
      UpdateProfileResponse(updatedAtUs: (m['updatedAt'] as int?) ?? 0);
}

// ── searchProfiles ──────────────────────────────────────────────────────────

class SearchProfilesRequest extends RpcRequest {
  final String query;
  final int? limit;
  final String? cursor;

  const SearchProfilesRequest({required this.query, this.limit, this.cursor});

  @override
  String get method => 'searchProfiles';

  @override
  Map<String, dynamic> toMap() => {
        'query': query,
        if (limit != null) 'limit': limit,
        if (cursor != null) 'cursor': cursor,
      };
}

class ProfileSearchItem {
  final Uint8List publicKey;
  final String username;
  final String? displayName;

  const ProfileSearchItem({
    required this.publicKey,
    required this.username,
    this.displayName,
  });

  static ProfileSearchItem fromMap(Map<String, dynamic> m) => ProfileSearchItem(
        publicKey: m['publicKey'] as Uint8List,
        username: m['username'] as String? ?? '',
        displayName: m['displayName'] as String?,
      );
}

class SearchProfilesResponse {
  final List<ProfileSearchItem> items;
  final String? nextCursor;

  const SearchProfilesResponse({required this.items, this.nextCursor});

  static SearchProfilesResponse fromMap(Map<String, dynamic> m) {
    final rawItems = m['items'] as List<dynamic>? ?? [];
    return SearchProfilesResponse(
      items: rawItems
          .map((e) => ProfileSearchItem.fromMap(e as Map<String, dynamic>))
          .toList(),
      nextCursor: m['nextCursor'] as String?,
    );
  }
}

// ── getProfileAvatar ────────────────────────────────────────────────────────

class GetProfileAvatarRequest extends RpcRequest {
  final Uint8List userPublicKey;

  const GetProfileAvatarRequest({required this.userPublicKey});

  @override
  String get method => 'getProfileAvatar';

  @override
  Map<String, dynamic> toMap() => {'userPublicKey': userPublicKey};
}

class GetProfileAvatarResponse {
  final Uint8List avatarBytes;
  final String contentType;

  const GetProfileAvatarResponse({
    required this.avatarBytes,
    required this.contentType,
  });

  static GetProfileAvatarResponse fromMap(Map<String, dynamic> m) =>
      GetProfileAvatarResponse(
        avatarBytes: m['avatarBytes'] as Uint8List? ?? Uint8List(0),
        contentType: m['contentType'] as String? ?? 'image/jpeg',
      );
}
