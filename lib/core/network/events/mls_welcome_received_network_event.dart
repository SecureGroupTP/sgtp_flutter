import 'dart:typed_data';

import 'package:sgtp_flutter/core/network/events/sgtp_server_event.dart';

class MlsWelcomeReceivedNetworkEvent extends SgtpServerEvent {
  const MlsWelcomeReceivedNetworkEvent({
    required this.targetUserPublicKey,
    required this.welcomeBytes,
  });

  final Uint8List targetUserPublicKey;
  final Uint8List welcomeBytes;

  factory MlsWelcomeReceivedNetworkEvent.fromParameters(
    Map<String, dynamic> parameters,
  ) {
    return MlsWelcomeReceivedNetworkEvent(
      targetUserPublicKey:
          (parameters['targetUserPublicKey'] as Uint8List?) ?? Uint8List(0),
      welcomeBytes: (parameters['welcomeBytes'] as Uint8List?) ?? Uint8List(0),
    );
  }

  @override
  String get type => 'mlsWelcomeReceived';
}
