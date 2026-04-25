import 'dart:typed_data';

import 'package:sgtp_flutter/core/network/sgtp_connection_service.dart';
import 'package:sgtp_flutter/features/messaging/data/services/server_v2_mls_client.dart';
import 'package:sgtp_flutter/features/messaging/domain/entities/direct_room_binding.dart';
import 'package:sgtp_flutter/features/messaging/domain/entities/sgtp_config.dart';
import 'package:sgtp_flutter/features/messaging/domain/repositories/direct_room_gateway.dart';

class SharedDirectRoomGateway implements DirectRoomGateway {
  SharedDirectRoomGateway({
    required SgtpConnectionService connectionService,
  }) : _connectionService = connectionService;

  final SgtpConnectionService _connectionService;

  @override
  Future<DirectRoomBinding> ensureDirectRoom({
    required SgtpConfig config,
    required Uint8List targetUserPublicKey,
  }) async {
    await _connectionService.configure(config);
    final client = ServerV2MlsClient(
      rpcProvider: _connectionService.ensureConnected,
      sharedServerEvents: _connectionService.serverEvents,
    );
    await client.connect();
    try {
      final response = await client.createDirectRoom(
        targetUserPublicKey: targetUserPublicKey,
      );
      return DirectRoomBinding(
        roomId: _normalizeRoomId(response.roomId),
        alreadyExisted: response.alreadyExisted,
      );
    } finally {
      await client.close();
    }
  }
}

String _normalizeRoomId(String roomId) =>
    roomId.trim().toLowerCase().replaceAll('-', '');
