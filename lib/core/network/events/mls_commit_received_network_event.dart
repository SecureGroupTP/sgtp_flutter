import 'dart:typed_data';

import 'package:sgtp_flutter/core/network/events/sgtp_server_event.dart';

class MlsCommitReceivedNetworkEvent extends SgtpServerEvent {
  const MlsCommitReceivedNetworkEvent({
    required this.roomId,
    required this.commitBytes,
  });

  final String roomId;
  final Uint8List commitBytes;

  factory MlsCommitReceivedNetworkEvent.fromParameters(
    Map<String, dynamic> parameters,
  ) {
    return MlsCommitReceivedNetworkEvent(
      roomId: (parameters['roomId'] as String?) ?? '',
      commitBytes: (parameters['commitBytes'] as Uint8List?) ?? Uint8List(0),
    );
  }

  @override
  String get type => 'mlsCommitReceived';
}
