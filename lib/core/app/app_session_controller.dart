import 'dart:typed_data';

import 'package:sgtp_flutter/features/messaging/domain/entities/direct_room_binding.dart';
import 'package:sgtp_flutter/features/messaging/domain/entities/sgtp_config.dart';
import 'package:sgtp_flutter/features/setup/domain/entities/contact_directory_models.dart';

abstract interface class AppSessionController {
  void applyAccountConfig({
    required String accountId,
    required SgtpConfig config,
    required Map<String, String> nicknames,
    required String serverAddress,
    required List<WhitelistEntry> whitelistEntries,
  });

  void setCurrentUserAvatar(Uint8List? avatar);

  void setCurrentNickname(String nickname);

  Future<String?> setCurrentUsername(String username);

  void setWhitelistEntries(List<WhitelistEntry> entries);

  Future<bool> respondToFriend(String peerPubkeyHex, bool accept);

  Future<DirectRoomBinding?> openDirectMessage(String peerPubkeyHex);
}
