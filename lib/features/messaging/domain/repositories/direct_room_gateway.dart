import 'dart:typed_data';

import 'package:sgtp_flutter/features/messaging/domain/entities/direct_room_binding.dart';
import 'package:sgtp_flutter/features/messaging/domain/entities/sgtp_config.dart';

abstract class DirectRoomGateway {
  Future<DirectRoomBinding> ensureDirectRoom({
    required SgtpConfig config,
    required Uint8List targetUserPublicKey,
  });
}
