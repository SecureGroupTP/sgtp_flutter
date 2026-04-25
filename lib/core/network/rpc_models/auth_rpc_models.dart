import 'dart:typed_data';

import 'package:sgtp_flutter/core/network/rpc_models/rpc_request.dart';
import 'package:sgtp_flutter/core/uuid_v7.dart';

// ── requestAuthChallenge ────────────────────────────────────────────────────

class RequestAuthChallengeRequest extends RpcRequest {
  final Uint8List userPublicKey;
  final String publicIp;
  final String deviceId;
  final Uint8List clientNonce;

  const RequestAuthChallengeRequest({
    required this.userPublicKey,
    required this.publicIp,
    required this.deviceId,
    required this.clientNonce,
  });

  @override
  String get method => 'requestAuthChallenge';

  @override
  bool get requiresAuth => false;

  @override
  Map<String, dynamic> toMap() => {
        'userPublicKey': userPublicKey,
        'publicIp': publicIp,
        'deviceId': deviceId,
        'clientNonce': clientNonce,
      };
}

class RequestAuthChallengeResponse {
  final String sessionId;
  final Uint8List challengePayload;
  final int expiresAtUs; // microseconds since epoch

  const RequestAuthChallengeResponse({
    required this.sessionId,
    required this.challengePayload,
    required this.expiresAtUs,
  });

  static RequestAuthChallengeResponse fromMap(Map<String, dynamic> m) =>
      RequestAuthChallengeResponse(
        sessionId: m['sessionId'] as String,
        challengePayload: m['challengePayload'] as Uint8List,
        expiresAtUs: parseTimestampUs(m['expiresAt']),
      );
}

// ── solveAuthChallenge ──────────────────────────────────────────────────────

class SolveAuthChallengeRequest extends RpcRequest {
  final String sessionId;
  final Uint8List signature;

  const SolveAuthChallengeRequest({
    required this.sessionId,
    required this.signature,
  });

  @override
  String get method => 'solveAuthChallenge';

  @override
  bool get requiresAuth => false;

  @override
  Map<String, dynamic> toMap() => {
        'sessionId': hexToBytes(sessionId.replaceAll('-', '')),
        'signature': signature,
      };
}

class SolveAuthChallengeResponse {
  final bool isAuthenticated;
  final Uint8List userPublicKey;
  final int serverTimeUs; // microseconds since epoch

  const SolveAuthChallengeResponse({
    required this.isAuthenticated,
    required this.userPublicKey,
    required this.serverTimeUs,
  });

  static SolveAuthChallengeResponse fromMap(Map<String, dynamic> m) =>
      SolveAuthChallengeResponse(
        isAuthenticated: (m['isAuthenticated'] as bool?) ?? false,
        userPublicKey: m['userPublicKey'] as Uint8List,
        serverTimeUs: parseTimestampUs(m['serverTime']),
      );
}

// ── subscribeToEvents ───────────────────────────────────────────────────────

class SubscribeToEventsRequest extends RpcRequest {
  final int requestedAtUs; // microseconds since epoch

  const SubscribeToEventsRequest({required this.requestedAtUs});

  @override
  String get method => 'subscribeToEvents';

  @override
  Map<String, dynamic> toMap() => {'requestedAt': requestedAtUs};
}

class SubscribeToEventsResponse {
  final String subscriptionId;
  final int subscribedAtUs;

  const SubscribeToEventsResponse({
    required this.subscriptionId,
    required this.subscribedAtUs,
  });

  static SubscribeToEventsResponse fromMap(Map<String, dynamic> m) =>
      SubscribeToEventsResponse(
        subscriptionId: m['subscriptionId'] as String? ?? '',
        subscribedAtUs: parseTimestampUs(m['subscribedAt']),
      );
}

// ── unsubscribeFromEvents ───────────────────────────────────────────────────

class UnsubscribeFromEventsRequest extends RpcRequest {
  final String subscriptionId;
  final int requestedAtUs; // microseconds since epoch

  const UnsubscribeFromEventsRequest({
    required this.subscriptionId,
    required this.requestedAtUs,
  });

  @override
  String get method => 'unsubscribeFromEvents';

  @override
  Map<String, dynamic> toMap() => {
        'subscriptionId': hexToBytes(subscriptionId.replaceAll('-', '')),
        'requestedAt': requestedAtUs,
      };
}

class UnsubscribeFromEventsResponse {
  final int unsubscribedAtUs;

  const UnsubscribeFromEventsResponse({required this.unsubscribedAtUs});

  static UnsubscribeFromEventsResponse fromMap(Map<String, dynamic> m) =>
      UnsubscribeFromEventsResponse(
        unsubscribedAtUs: parseTimestampUs(m['unsubscribedAt']),
      );
}

// ── acknowledgeEvent ────────────────────────────────────────────────────────

class AcknowledgeEventRequest extends RpcRequest {
  final Uint8List eventId;
  final String? segmentId;

  const AcknowledgeEventRequest({required this.eventId, this.segmentId});

  @override
  String get method => 'acknowledgeEvent';

  @override
  Map<String, dynamic> toMap() => {
        'eventId': eventId,
        if (segmentId != null) 'segmentId': segmentId,
      };
}

class AcknowledgeEventResponse {
  const AcknowledgeEventResponse();

  static AcknowledgeEventResponse fromMap(Map<String, dynamic> _) =>
      const AcknowledgeEventResponse();
}
