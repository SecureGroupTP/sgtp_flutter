import 'dart:typed_data';

import 'package:sgtp_flutter/core/storage/local_encryption_service.dart';
import 'package:sgtp_flutter/features/messaging/domain/entities/sgtp_config.dart';
import 'package:sgtp_flutter/features/setup/domain/entities/contact_directory_models.dart';

enum AppStartupAction {
  showOnboarding,
  unlockLocalEncryption,
  openHome,
  retry,
}

class HomeLaunchData {
  const HomeLaunchData({
    required this.accountId,
    required this.config,
    required this.nicknames,
    required this.serverAddress,
    required this.userAvatar,
    required this.initialContacts,
  });

  final String accountId;
  final SgtpConfig config;
  final Map<String, String> nicknames;
  final String serverAddress;
  final Uint8List? userAvatar;
  final List<ContactEntry> initialContacts;
}

class AppStartupResult {
  const AppStartupResult._({
    required this.action,
    this.homeLaunchData,
    this.localEncryptionState,
  });

  final AppStartupAction action;
  final HomeLaunchData? homeLaunchData;
  final LocalEncryptionState? localEncryptionState;

  const AppStartupResult.showOnboarding()
      : this._(action: AppStartupAction.showOnboarding);

  const AppStartupResult.retry() : this._(action: AppStartupAction.retry);

  const AppStartupResult.unlockLocalEncryption(LocalEncryptionState state)
      : this._(
          action: AppStartupAction.unlockLocalEncryption,
          localEncryptionState: state,
        );

  const AppStartupResult.openHome(HomeLaunchData data)
      : this._(
          action: AppStartupAction.openHome,
          homeLaunchData: data,
        );
}
