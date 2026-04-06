import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:sgtp_flutter/features/contacts/application/services/contacts_directory_service.dart';
import 'package:sgtp_flutter/features/contacts/application/viewmodels/contacts_cubit.dart';
import 'package:sgtp_flutter/features/contacts/presentation/pages/contacts_screen.dart';
import 'package:sgtp_flutter/features/setup/domain/entities/contact_directory_models.dart';

class ContactsPage extends StatefulWidget {
  const ContactsPage({
    super.key,
    required this.accountId,
    this.serverNodeId,
    this.myPubkeyHex,
    required this.initialEntries,
    required this.onEntriesChanged,
    this.contactProfiles = const {},
    this.friendStates = const {},
    this.onFriendRespond,
    this.onOpenDm,
  });

  final String accountId;
  final String? serverNodeId;
  final String? myPubkeyHex;
  final List<WhitelistEntry> initialEntries;
  final Map<String, ContactProfile> contactProfiles;
  final Map<String, FriendStateRecord> friendStates;
  final void Function(List<WhitelistEntry> entries) onEntriesChanged;
  final Future<bool> Function(String peerPubkeyHex, bool accept)?
      onFriendRespond;
  final void Function(String roomUUIDHex)? onOpenDm;

  @override
  State<ContactsPage> createState() => _ContactsPageState();
}

class _ContactsPageState extends State<ContactsPage> {
  late final ContactsCubit _contactsCubit;

  @override
  void initState() {
    super.initState();
    _contactsCubit = ContactsCubit(
      directoryService: context.read<ContactsDirectoryService>(),
      onEntriesChanged: widget.onEntriesChanged,
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
      child: ContactsScreen(
        onFriendRespond: widget.onFriendRespond,
        onOpenDm: widget.onOpenDm,
      ),
    );
  }
}
