/// Role of a member within a chat room.
enum ChatRoleEnum {
  member(1),
  admin(2),
  owner(3);

  const ChatRoleEnum(this.value);
  final int value;

  static ChatRoleEnum fromValue(int v) =>
      values.firstWhere((e) => e.value == v, orElse: () => ChatRoleEnum.member);
}

/// Visibility and join policy of a chat room.
enum ChatRoomVisibilityEnum {
  public(1),
  linkOnly(2),
  private(3);

  const ChatRoomVisibilityEnum(this.value);
  final int value;

  static ChatRoomVisibilityEnum fromValue(int v) =>
      values.firstWhere((e) => e.value == v,
          orElse: () => ChatRoomVisibilityEnum.private);
}

/// Workflow state of a friend request.
enum FriendRequestStateEnum {
  pending(1),
  accepted(2),
  declined(3),
  canceled(4);

  const FriendRequestStateEnum(this.value);
  final int value;

  static FriendRequestStateEnum fromValue(int v) =>
      values.firstWhere((e) => e.value == v,
          orElse: () => FriendRequestStateEnum.pending);
}

/// State of a chat room invitation.
enum InvitationStateEnum {
  pending(1),
  accepted(2),
  declined(3),
  revoked(4);

  const InvitationStateEnum(this.value);
  final int value;

  static InvitationStateEnum fromValue(int v) =>
      values.firstWhere((e) => e.value == v,
          orElse: () => InvitationStateEnum.pending);
}

/// Platform identifier for device registration.
enum PlatformEnum {
  ios(1),
  android(2),
  web(3),
  desktop(4);

  const PlatformEnum(this.value);
  final int value;

  static PlatformEnum fromValue(int v) =>
      values.firstWhere((e) => e.value == v, orElse: () => PlatformEnum.desktop);
}
