import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:sgtp_flutter/core/app/app_session_controller.dart';
import 'package:sgtp_flutter/features/contacts/application/services/contacts_directory_service.dart';
import 'package:sgtp_flutter/features/contacts/application/viewmodels/contacts_cubit.dart';
import 'package:sgtp_flutter/features/contacts/presentation/pages/contacts_screen.dart';
import 'package:sgtp_flutter/features/setup/domain/entities/contact_directory_models.dart';
import 'package:sgtp_flutter/features/shell/application/viewmodels/home_cubit.dart';

class ContactsPage extends StatefulWidget {
  const ContactsPage({
    super.key,
    required this.accountId,
    this.serverNodeId,
    this.myPubkeyHex,
    required this.initialEntries,
    this.contactProfiles = const {},
    this.friendStates = const {},
  });

  final String accountId;
  final String? serverNodeId;
  final String? myPubkeyHex;
  final List<WhitelistEntry> initialEntries;
  final Map<String, ContactProfile> contactProfiles;
  final Map<String, FriendStateRecord> friendStates;

  @override
  State<ContactsPage> createState() => _ContactsPageState();
}

class _ContactsPageState extends State<ContactsPage> {
  late final ContactsCubit _contactsCubit;

  @override
  void initState() {
    super.initState();
    final homeCubit = context.read<HomeCubit>();
    _contactsCubit = ContactsCubit(
      directoryService: context.read<ContactsDirectoryService>(),
      activeClientProvider: () => homeCubit.activeUserDirClient,
      appSessionController: context.read<AppSessionController>(),
      accountId: widget.accountId,
      serverNodeId: widget.serverNodeId,
      myPubkeyHex: widget.myPubkeyHex,
      initialEntries: widget.initialEntries,
      contactProfiles: widget.contactProfiles,
      friendStates: widget.friendStates,
    );
  }

  @override
  void didUpdateWidget(covariant ContactsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    _contactsCubit.syncExternalData(
      accountId: widget.accountId,
      serverNodeId: widget.serverNodeId,
      myPubkeyHex: widget.myPubkeyHex,
      initialEntries: widget.initialEntries,
      contactProfiles: widget.contactProfiles,
      friendStates: widget.friendStates,
    );
  }

  @override
  void dispose() {
    _contactsCubit.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return BlocProvider.value(
      value: _contactsCubit,
      child: const ContactsScreen(),
    );
  }
}
