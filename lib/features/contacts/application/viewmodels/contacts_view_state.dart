import 'package:sgtp_flutter/features/contacts/application/models/contacts_models.dart';

class ContactsViewState {
  const ContactsViewState({
    this.searchQuery = '',
    this.isSearchingServer = false,
    this.serverSearchHit,
    this.recentlyAddedUsername,
    this.contacts = const <ContactsContactUiModel>[],
    this.incomingRequests = const <ContactsIncomingRequestUiModel>[],
    this.totalContacts = 0,
  });

  final String searchQuery;
  final bool isSearchingServer;
  final ContactsServerSearchHitUiModel? serverSearchHit;
  final String? recentlyAddedUsername;
  final List<ContactsContactUiModel> contacts;
  final List<ContactsIncomingRequestUiModel> incomingRequests;
  final int totalContacts;

  bool get hasAnyContacts => totalContacts > 0;
}
