import 'dart:typed_data';

import 'package:sgtp_flutter/core/network/events/connection_events.dart';
import 'package:sgtp_flutter/features/messaging/domain/entities/sgtp_config.dart';
import 'package:sgtp_flutter/features/setup/domain/entities/contact_directory_models.dart';

class HomeViewState {
  const HomeViewState({
    required this.accountId,
    required this.config,
    required this.nicknames,
    required this.serverAddress,
    this.userAvatar,
    this.contacts = const [],
    this.contactProfiles = const {},
    this.friendStates = const {},
    this.nickname = '',
    this.username = '',
    this.connectionStatus = SgtpConnectionStatus.disconnected,
    this.connectionError,
    this.currentTabIndex = 0,
  });

  final String accountId;
  final SgtpConfig config;
  final Map<String, String> nicknames;
  final String serverAddress;
  final Uint8List? userAvatar;
  final List<ContactEntry> contacts;
  final Map<String, ContactProfile> contactProfiles;
  final Map<String, FriendStateRecord> friendStates;
  final String nickname;
  final String username;
  final SgtpConnectionStatus connectionStatus;
  final String? connectionError;
  final int currentTabIndex;

  String? get myPubkeyHex {
    if (config.myPublicKey.isEmpty) return null;
    return config.myPublicKey
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
  }
}

