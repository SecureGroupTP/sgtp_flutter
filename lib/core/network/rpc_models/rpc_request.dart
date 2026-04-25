/// Parses a timestamp field that may arrive as microseconds [int] or as an
/// ISO-8601 string from the server.
int parseTimestampUs(dynamic value) {
  if (value is int) return value;
  if (value is String) {
    final dt = DateTime.tryParse(value);
    if (dt != null) return dt.microsecondsSinceEpoch;
  }
  return 0;
}

/// Base class for all CBOR-RPC request objects.
///
/// Each concrete request carries its own [method] name and knows how to
/// serialize itself to a parameter map via [toMap].
abstract class RpcRequest {
  const RpcRequest();

  /// The RPC method name sent in the `rpcCall` field of the CBOR packet.
  String get method;

  /// Parameters map that is encoded into the `parameters` field.
  Map<String, dynamic> toMap();

  /// Whether this request must wait for authentication before being sent.
  ///
  /// Auth-handshake requests ([RequestAuthChallengeRequest],
  /// [SolveAuthChallengeRequest]) override this to `false` so they are
  /// dispatched immediately. All other requests default to `true` and are
  /// held in the send queue until [SgtpRpcClient.setCredentials] is called.
  bool get requiresAuth => true;
}
