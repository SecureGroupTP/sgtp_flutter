import 'package:sgtp_flutter/features/messaging/data/repositories/chat_history_repository.dart';
import 'package:sgtp_flutter/features/messaging/data/repositories/chat_metadata_repository.dart';
import 'package:sgtp_flutter/features/messaging/domain/entities/chat_metadata.dart';
import 'package:sgtp_flutter/features/messaging/domain/repositories/chat_storage_gateway.dart';

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
  const DefaultChatStorageGateway();

  @override
  ChatMetadataStore metadataForAccount(String accountId) {
    return _ChatMetadataStoreAdapter(
      ChatMetadataRepository(accountId: accountId),
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
      ),
    );
  }
}
