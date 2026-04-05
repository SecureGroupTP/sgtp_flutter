import 'dart:async';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'package:sgtp_flutter/core/sgtp_server_options.dart';
import 'package:sgtp_flutter/features/contacts/domain/models/user_dir_models.dart';
import 'package:sgtp_flutter/features/setup/domain/entities/node.dart';

export 'package:sgtp_flutter/features/contacts/domain/models/user_dir_models.dart';

typedef UserDirClientFactory = IUserDirClient? Function(
  NodeConfig node,
  SgtpServerOptions opts,
);

abstract class IUserDirClient {
  String get label;
  bool get isConnected;

  Stream<UserDirMeta> get notifyStream;
  Stream<UserDirFriendNotify> get friendNotifyStream;

  Future<void> connect();
  void close();

  Future<({bool ok, int? errorCode, String? errorMessage})> registerWithResult({
    required String username,
    required String fullname,
    required Uint8List pubkey,
    required Uint8List avatarBytes,
    required SimpleKeyPairData identityKeyPair,
  });

  Future<UserDirMeta?> getMeta(Uint8List pubkey);
  Future<UserDirProfile?> getProfile(Uint8List pubkey);
  Future<bool> subscribe(List<Uint8List> pubkeys);
  Future<List<UserDirMeta>> search(String query, {int limit = 20});

  Future<bool> sendFriendRequest({
    required Uint8List myPubkey,
    required Uint8List peerPubkey,
    required SimpleKeyPairData identityKeyPair,
  });

  Future<bool> sendFriendResponse({
    required Uint8List myPubkey,
    required Uint8List requesterPubkey,
    required bool accept,
    required SimpleKeyPairData identityKeyPair,
  });

  Future<bool> sendFriendDelete({
    required Uint8List myPubkey,
    required Uint8List peerPubkey,
    required SimpleKeyPairData identityKeyPair,
  });

  Future<List<UserDirFriendState>?> friendSync({
    required Uint8List myPubkey,
    required SimpleKeyPairData identityKeyPair,
  });
}
