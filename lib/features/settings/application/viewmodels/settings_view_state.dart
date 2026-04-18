import 'dart:typed_data';

import 'package:sgtp_flutter/core/constants.dart';
import 'package:sgtp_flutter/features/setup/domain/entities/contact_directory_models.dart';
import 'package:sgtp_flutter/features/setup/domain/entities/node.dart';

class SettingsViewState {
  const SettingsViewState({
    this.privateKeyPath,
    this.privateKeyBytes,
    this.myPublicKey,
    this.contactEntries = const [],
    this.userAvatar,
    this.nickname = '',
    this.username = '',
    this.avatarsByNodeId = const {},
    this.nicknamesByNodeId = const {},
    this.isLoading = false,
    this.isGenerating = false,
    this.isCreatingBackup = false,
    this.isRestoringBackup = false,
    this.usernameError,
    this.pingIntervalSeconds = 30,
    this.compressFiles = false,
    this.compressPhotos = false,
    this.compressVideos = false,
    this.mediaChunkSizeBytes = SgtpConstants.defaultMediaChunkSize,
    this.doubleTapDesktop = 'react',
    this.swipeToReply = true,
    this.longPressMenu = true,
    this.nodes = const [],
    this.accountIdsList = const [],
    this.nodesLoading = true,
    this.preferredNodeId,
    this.preferredAccountId,
    this.standaloneServerAddress = '',
  });

  final String? privateKeyPath;
  final Uint8List? privateKeyBytes;
  final Uint8List? myPublicKey;
  final List<ContactEntry> contactEntries;
  final Uint8List? userAvatar;
  final String nickname;
  final String username;
  final Map<String, Uint8List?> avatarsByNodeId;
  final Map<String, String> nicknamesByNodeId;

  final bool isLoading;
  final bool isGenerating;
  final bool isCreatingBackup;
  final bool isRestoringBackup;
  final String? usernameError;

  final int pingIntervalSeconds;
  final bool compressFiles;
  final bool compressPhotos;
  final bool compressVideos;
  final int mediaChunkSizeBytes;

  final String doubleTapDesktop;
  final bool swipeToReply;
  final bool longPressMenu;

  final List<NodeConfig> nodes;
  final List<String> accountIdsList;
  final bool nodesLoading;
  final String? preferredNodeId;
  final String? preferredAccountId;
  final String standaloneServerAddress;

  String? get activeAccountId {
    final id = (preferredAccountId ?? '').trim();
    return id.isEmpty ? null : id;
  }
}

