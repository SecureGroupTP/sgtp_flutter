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

  // ── Auth + profile ───────────────────────────────────────────────────────

  /// Authenticates with the server and updates the user's profile.
  ///
  /// Internally performs the auth-challenge flow, then calls updateProfile.
  /// Returns `{ok: true}` on success, or `{ok: false, errorMessage: ...}` on
  /// failure.
  Future<({bool ok, String? errorMessage})> registerWithResult({
    required String username,
    required String fullname,
    required Uint8List pubkey,
    required Uint8List avatarBytes,
    required SimpleKeyPairData identityKeyPair,
    String? deviceId,
  });

  // ── Profile lookup ───────────────────────────────────────────────────────

  /// Lightweight profile metadata (no avatar bytes).
  Future<UserDirMeta?> getMeta(Uint8List pubkey);

  /// Full profile including avatar bytes.
  Future<UserDirProfile?> getProfile(Uint8List pubkey);

  /// Search profiles by username / display name substring.
  Future<List<UserDirMeta>> search(String query, {int limit = 20});

  // ── Event subscriptions ──────────────────────────────────────────────────

  /// Subscribe to real-time server events for the given public keys.
  /// Returns false if the subscription could not be established.
  Future<bool> subscribe(List<Uint8List> pubkeys);

  // ── Friend operations ────────────────────────────────────────────────────

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
