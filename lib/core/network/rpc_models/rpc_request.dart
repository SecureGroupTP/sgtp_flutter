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
}
