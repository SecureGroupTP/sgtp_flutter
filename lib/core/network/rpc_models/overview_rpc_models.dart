import 'package:sgtp_flutter/core/network/rpc_models/rpc_request.dart';

class GetServerConfigRequest extends RpcRequest {
  const GetServerConfigRequest();

  @override
  String get method => 'getServerConfig';

  @override
  Map<String, dynamic> toMap() => const {};
}
