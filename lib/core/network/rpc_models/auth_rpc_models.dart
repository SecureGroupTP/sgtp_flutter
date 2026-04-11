import 'dart:typed_data';

// ── requestAuthChallenge ────────────────────────────────────────────────────

class RequestAuthChallengeRequest {
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
        expiresAtUs: (m['expiresAt'] as int?) ?? 0,
      );
}

// ── solveAuthChallenge ──────────────────────────────────────────────────────

class SolveAuthChallengeRequest {
  final String sessionId;
  final Uint8List signature;

  const SolveAuthChallengeRequest({
    required this.sessionId,
    required this.signature,
  });

  Map<String, dynamic> toMap() => {
        'sessionId': sessionId,
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
        serverTimeUs: (m['serverTime'] as int?) ?? 0,
      );
}

// ── subscribeToEvents ───────────────────────────────────────────────────────

class SubscribeToEventsRequest {
  final int requestedAtUs; // microseconds since epoch

  const SubscribeToEventsRequest({required this.requestedAtUs});

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
        subscribedAtUs: (m['subscribedAt'] as int?) ?? 0,
      );
}
