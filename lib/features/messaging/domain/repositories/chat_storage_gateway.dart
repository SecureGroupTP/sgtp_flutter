import 'package:sgtp_flutter/features/messaging/application/models/messaging_models.dart';

abstract class ChatMetadataStore {
  Future<void> saveChat(ChatMetadata metadata);
  Future<void> updateChat(ChatMetadata metadata);
  Future<ChatMetadata?> loadChat(String uuid, {String? serverAddress});
  Future<List<ChatMetadata>> loadAllChats();
  Future<void> deleteChat(String uuid, {String? serverAddress});
}

abstract class ChatHistoryStore {
  Future<void> clear();
}

abstract class ChatStorageGateway {
  ChatMetadataStore metadataForAccount(String accountId);

  ChatHistoryStore historyForChat({
    required String accountId,
    required String serverAddress,
    required String chatUUID,
  });
}
