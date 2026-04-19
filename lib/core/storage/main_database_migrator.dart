import 'main_database_schema.dart';

class MainDatabaseMigration {
  const MainDatabaseMigration({
    required this.version,
    required this.statements,
  });

  final int version;
  final List<String> statements;
}

class MainDatabaseMigrator {
  const MainDatabaseMigrator();

  List<MainDatabaseMigration> get migrations => const [
        MainDatabaseMigration(
          version: 1,
          statements: [
            '''
CREATE TABLE IF NOT EXISTS ${MainDatabaseSchema.settingsTable} (
  record_key TEXT PRIMARY KEY,
  nonce BLOB NOT NULL,
  ciphertext BLOB NOT NULL,
  updated_at INTEGER NOT NULL
)
''',
            '''
CREATE TABLE IF NOT EXISTS ${MainDatabaseSchema.chatMetadataTable} (
  room_uuid TEXT NOT NULL,
  server_address TEXT NOT NULL,
  updated_at INTEGER NOT NULL,
  nonce BLOB NOT NULL,
  ciphertext BLOB NOT NULL,
  PRIMARY KEY (room_uuid, server_address)
)
''',
            '''
CREATE INDEX IF NOT EXISTS idx_chat_metadata_updated_at
ON ${MainDatabaseSchema.chatMetadataTable}(updated_at DESC)
''',
            '''
CREATE TABLE IF NOT EXISTS ${MainDatabaseSchema.chatHistoryTable} (
  room_uuid TEXT NOT NULL,
  message_id TEXT NOT NULL,
  timestamp_ms INTEGER NOT NULL,
  nonce BLOB NOT NULL,
  ciphertext BLOB NOT NULL,
  PRIMARY KEY (room_uuid, message_id)
)
''',
            '''
CREATE INDEX IF NOT EXISTS idx_chat_history_room_timestamp
ON ${MainDatabaseSchema.chatHistoryTable}(room_uuid, timestamp_ms, message_id)
''',
          ],
        ),
        MainDatabaseMigration(
          version: 2,
          statements: [
            '''
CREATE TABLE IF NOT EXISTS ${MainDatabaseSchema.contactEntriesTable} (
  peer_pubkey_hex TEXT PRIMARY KEY,
  updated_at INTEGER NOT NULL,
  nonce BLOB NOT NULL,
  ciphertext BLOB NOT NULL
)
''',
            '''
CREATE INDEX IF NOT EXISTS idx_contact_entries_updated_at
ON ${MainDatabaseSchema.contactEntriesTable}(updated_at DESC)
''',
            '''
CREATE TABLE IF NOT EXISTS ${MainDatabaseSchema.contactProfilesTable} (
  peer_pubkey_hex TEXT PRIMARY KEY,
  updated_at INTEGER NOT NULL,
  nonce BLOB NOT NULL,
  ciphertext BLOB NOT NULL
)
''',
            '''
CREATE INDEX IF NOT EXISTS idx_contact_profiles_updated_at
ON ${MainDatabaseSchema.contactProfilesTable}(updated_at DESC)
''',
            '''
CREATE TABLE IF NOT EXISTS ${MainDatabaseSchema.friendStatesTable} (
  peer_pubkey_hex TEXT PRIMARY KEY,
  updated_at INTEGER NOT NULL,
  nonce BLOB NOT NULL,
  ciphertext BLOB NOT NULL
)
''',
            '''
CREATE INDEX IF NOT EXISTS idx_friend_states_updated_at
ON ${MainDatabaseSchema.friendStatesTable}(updated_at DESC)
''',
            '''
CREATE TABLE IF NOT EXISTS ${MainDatabaseSchema.suppressedContactsTable} (
  peer_pubkey_hex TEXT PRIMARY KEY,
  updated_at INTEGER NOT NULL
)
''',
            '''
CREATE INDEX IF NOT EXISTS idx_suppressed_contacts_updated_at
ON ${MainDatabaseSchema.suppressedContactsTable}(updated_at DESC)
''',
          ],
        ),
        MainDatabaseMigration(
          version: 3,
          statements: [
            '''
CREATE TABLE IF NOT EXISTS ${MainDatabaseSchema.chatUiStateTable} (
  room_uuid TEXT PRIMARY KEY,
  updated_at INTEGER NOT NULL,
  nonce BLOB NOT NULL,
  ciphertext BLOB NOT NULL
)
''',
            '''
CREATE INDEX IF NOT EXISTS idx_chat_ui_state_updated_at
ON ${MainDatabaseSchema.chatUiStateTable}(updated_at DESC)
''',
          ],
        ),
      ];
}
