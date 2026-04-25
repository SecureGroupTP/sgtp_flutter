import 'package:sgtp_flutter/features/messaging/data/repositories/chat_history_repository.dart';
import 'package:sgtp_flutter/features/messaging/data/repositories/chat_metadata_repository.dart';
import 'package:sgtp_flutter/features/messaging/domain/entities/chat_metadata.dart';
import 'package:sgtp_flutter/features/messaging/domain/repositories/chat_storage_gateway.dart';
import 'package:sgtp_flutter/core/storage/main_database_factory.dart';

class _ChatMetadataStoreAdapter implements ChatMetadataStore {
  final ChatMetadataRepository _repo;

  const _ChatMetadataStoreAdapter(this._repo);

  @override
  Future<void> deleteChat(String uuid, {String? serverAddress}) {
    return _repo.deleteChat(uuid, serverAddress: serverAddress);
  }

  @override
  Future<List<ChatMetadata>> loadAllChats() => _repo.loadAllChats();

  @override
  Future<ChatMetadata?> loadChat(String uuid, {String? serverAddress}) {
    return _repo.loadChat(uuid, serverAddress: serverAddress);
  }

  @override
  Future<void> saveChat(ChatMetadata metadata) => _repo.saveChat(metadata);

  @override
  Future<void> updateChat(ChatMetadata metadata) => _repo.updateChat(metadata);
}

class _ChatHistoryStoreAdapter implements ChatHistoryStore {
  final ChatHistoryRepository _repo;

  const _ChatHistoryStoreAdapter(this._repo);

  @override
  Future<void> clear() => _repo.clear();
}

class DefaultChatStorageGateway implements ChatStorageGateway {
  DefaultChatStorageGateway({
    required MainDatabaseFactory mainDatabaseFactory,
  }) : _mainDatabaseFactory = mainDatabaseFactory;

  final MainDatabaseFactory _mainDatabaseFactory;

  String _serverKey(String raw) {
    return raw
        .trim()
        .replaceAll(RegExp(r'^https?://', caseSensitive: false), '')
        .replaceAll(RegExp(r'^wss?://', caseSensitive: false), '')
        .toLowerCase();
  }

  @override
  ChatMetadataStore metadataForAccount(String accountId) {
    return _ChatMetadataStoreAdapter(
      ChatMetadataRepository(
        accountId: accountId,
        mainDatabaseFactory: _mainDatabaseFactory,
      ),
    );
  }

  @override
  ChatHistoryStore historyForChat({
    required String accountId,
    required String serverAddress,
    required String chatUUID,
  }) {
    return _ChatHistoryStoreAdapter(
      ChatHistoryRepository(
        accountId: accountId,
        serverAddress: serverAddress,
        chatUUID: chatUUID,
        mainDatabaseFactory: _mainDatabaseFactory,
      ),
    );
  }

  @override
  Future<int> migrateServerAddress({
    required String accountId,
    required String fromServerAddress,
    required String toServerAddress,
  }) async {
    final acc = accountId.trim();
    final fromRaw = fromServerAddress.trim();
    final toRaw = toServerAddress.trim();
    if (acc.isEmpty || fromRaw.isEmpty || toRaw.isEmpty) return 0;
    if (_serverKey(fromRaw) == _serverKey(toRaw)) return 0;

    final metadataRepo = ChatMetadataRepository(
      accountId: acc,
      mainDatabaseFactory: _mainDatabaseFactory,
    );
    final all = await metadataRepo.loadAllChats();
    final source =
        all.where((m) => _serverKey(m.serverAddress) == _serverKey(fromRaw));
    var migrated = 0;

    for (final chat in source) {
      final oldServer = chat.serverAddress.trim();
      if (oldServer.isEmpty) continue;

      final next = chat.copyWith(
        serverAddress: toRaw,
        updatedAt: DateTime.now(),
      );
      await metadataRepo.saveChat(next);

      final oldHistory = ChatHistoryRepository(
        accountId: acc,
        serverAddress: oldServer,
        chatUUID: chat.uuid,
        mainDatabaseFactory: _mainDatabaseFactory,
      );
      final newHistory = ChatHistoryRepository(
        accountId: acc,
        serverAddress: toRaw,
        chatUUID: chat.uuid,
        mainDatabaseFactory: _mainDatabaseFactory,
      );

      const page = 250;
      var offset = 0;
      while (true) {
        final records = await oldHistory.readRange(offset: offset, limit: page);
        if (records.isEmpty) break;
        for (final record in records) {
          await newHistory.appendIfAbsent(record);
        }
        offset += records.length;
      }
      await oldHistory.clear();
      await metadataRepo.deleteChat(chat.uuid, serverAddress: oldServer);
      migrated++;
    }
    return migrated;
  }
}
