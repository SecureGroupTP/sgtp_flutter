import 'dart:typed_data';

import 'package:sgtp_flutter/features/messaging/domain/entities/sgtp_config.dart';
import 'package:sgtp_flutter/features/setup/domain/entities/contact_directory_models.dart';
import 'package:sgtp_flutter/features/shell/application/models/home_models.dart';

class HomeUserDirSession {
  const HomeUserDirSession({
    required this.accountId,
    required this.config,
    required this.whitelist,
    required this.nicknames,
    required this.nickname,
    required this.username,
    required this.userAvatar,
    required this.serverAddress,
    this.resolvedNode,
  });

  final String accountId;
  final SgtpConfig config;
  final List<WhitelistEntry> whitelist;
  final Map<String, String> nicknames;
  final String nickname;
  final String username;
  final Uint8List? userAvatar;
  final String serverAddress;

  /// The resolved server node used to create the RPC client.
  /// Null if the server options have not been discovered yet.
  final ResolvedUserDirNode? resolvedNode;
}

class HomeUserDirState {
  const HomeUserDirState({
    required this.contactProfiles,
    required this.friendStates,
    required this.suppressedContacts,
    required this.whitelist,
    required this.nicknames,
  });

  final Map<String, ContactProfile> contactProfiles;
  final Map<String, FriendStateRecord> friendStates;
  final Set<String> suppressedContacts;
  final List<WhitelistEntry> whitelist;
  final Map<String, String> nicknames;
}
