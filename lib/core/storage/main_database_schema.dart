class MainDatabaseSchema {
  static const currentVersion = 3;

  static const settingsTable = 'settings_records';
  static const contactEntriesTable = 'contact_entries';
  static const contactProfilesTable = 'contact_profiles';
  static const friendStatesTable = 'friend_states';
  static const suppressedContactsTable = 'suppressed_contacts';
  static const chatUiStateTable = 'chat_ui_state_records';
  static const chatMetadataTable = 'chat_metadata_records';
  static const chatHistoryTable = 'chat_history_records';
}
