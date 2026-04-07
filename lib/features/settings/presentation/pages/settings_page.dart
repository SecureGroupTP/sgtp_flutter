import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:sgtp_flutter/features/messaging/domain/entities/sgtp_config.dart';
import 'package:sgtp_flutter/features/settings/application/services/settings_management_service.dart';
import 'package:sgtp_flutter/features/settings/application/viewmodels/settings_cubit.dart';
import 'package:sgtp_flutter/features/settings/presentation/pages/settings_screen.dart';

class SettingsPage extends StatefulWidget {
  final SgtpConfig? initialConfig;
  final Map<String, String>? initialNicknames;
  final ConfigChangedCallback? onConfigChanged;
  final UserAvatarChangedCallback? onUserAvatarChanged;
  final Uint8List? currentUserAvatar;
  final void Function(String nickname)? onNicknameChanged;
  final Future<String?> Function(String username)? onUsernameChanged;
  final VoidCallback? onAllDataDeleted;

  const SettingsPage({
    super.key,
    this.initialConfig,
    this.initialNicknames,
    this.onConfigChanged,
    this.onUserAvatarChanged,
    this.currentUserAvatar,
    this.onNicknameChanged,
    this.onUsernameChanged,
    this.onAllDataDeleted,
  });

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final SettingsCubit _cubit;

  @override
  void initState() {
    super.initState();
    _cubit = SettingsCubit(
      settings: context.read<SettingsManagementService>(),
      initialConfig: widget.initialConfig,
      initialNicknames: widget.initialNicknames,
      currentUserAvatar: widget.currentUserAvatar,
      onConfigChanged: widget.onConfigChanged,
      onUserAvatarChanged: widget.onUserAvatarChanged,
      onNicknameChanged: widget.onNicknameChanged,
      onUsernameChanged: widget.onUsernameChanged,
      onAllDataDeleted: widget.onAllDataDeleted,
    );
  }

  @override
  void dispose() {
    _cubit.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return BlocProvider.value(
      value: _cubit,
      child: const SettingsScreen(),
    );
  }
}
