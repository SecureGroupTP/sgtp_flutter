import 'dart:typed_data';

import 'package:sgtp_flutter/core/network/events/event_decode.dart';
import 'package:sgtp_flutter/core/network/events/sgtp_server_event.dart';

class MlsWelcomeReceivedNetworkEvent extends SgtpServerEvent {
  const MlsWelcomeReceivedNetworkEvent({
    required this.targetUserPublicKey,
    required this.welcomeBytes,
    this.deferredEventId,
    this.deferredSegmentId,
  });

  final Uint8List targetUserPublicKey;
  final Uint8List welcomeBytes;

  /// Raw eventId of the server-pushed packet whose ack was deferred.
  ///
  /// Non-null only when the network layer skipped auto-ack so the application
  /// layer must explicitly acknowledge after successful processing.
  final Uint8List? deferredEventId;

  /// Segment id used by the server outbox for this event, if any.
  final String? deferredSegmentId;

  factory MlsWelcomeReceivedNetworkEvent.fromParameters(
    Map<String, dynamic> parameters, {
    Uint8List? deferredEventId,
    String? deferredSegmentId,
  }) {
    return MlsWelcomeReceivedNetworkEvent(
      targetUserPublicKey: decodeEventBytes(parameters['targetUserPublicKey']),
      welcomeBytes: decodeEventBytes(parameters['welcomeBytes']),
      deferredEventId: deferredEventId,
      deferredSegmentId: deferredSegmentId,
    );
  }

  @override
  String get type => 'mlsWelcomeReceived';
}
