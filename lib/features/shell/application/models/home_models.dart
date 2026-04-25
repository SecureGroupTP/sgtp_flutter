import 'dart:typed_data';

import 'package:sgtp_flutter/core/sgtp_server_options.dart';
import 'package:sgtp_flutter/features/setup/domain/entities/contact_directory_models.dart';
import 'package:sgtp_flutter/features/setup/domain/entities/node.dart';

class HomeAccountState {
  const HomeAccountState({
    required this.nickname,
    required this.username,
    required this.userAvatar,
    required this.friendStates,
    required this.suppressedContacts,
  });

  final String nickname;
  final String username;
  final Uint8List? userAvatar;
  final Map<String, FriendStateRecord> friendStates;
  final Set<String> suppressedContacts;
}

class ResolvedUserDirNode {
  const ResolvedUserDirNode({
    required this.node,
    required this.options,
  });

  final NodeConfig node;
  final SgtpServerOptions options;
}
