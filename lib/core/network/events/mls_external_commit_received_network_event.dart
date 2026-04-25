import 'dart:typed_data';

import 'package:sgtp_flutter/core/network/events/event_decode.dart';
import 'package:sgtp_flutter/core/network/events/sgtp_server_event.dart';

class MlsExternalCommitReceivedNetworkEvent extends SgtpServerEvent {
  const MlsExternalCommitReceivedNetworkEvent({
    required this.roomId,
    required this.commitBytes,
    required this.joinerPublicKey,
  });

  final String roomId;
  final Uint8List commitBytes;
  final Uint8List joinerPublicKey;

  factory MlsExternalCommitReceivedNetworkEvent.fromParameters(
    Map<String, dynamic> parameters,
  ) {
    return MlsExternalCommitReceivedNetworkEvent(
      roomId: (parameters['roomId'] as String?) ?? '',
      commitBytes: decodeEventBytes(parameters['commitBytes']),
      joinerPublicKey: decodeEventBytes(parameters['joinerPublicKey']),
    );
  }

  @override
  String get type => 'mlsExternalCommitReceived';
}
