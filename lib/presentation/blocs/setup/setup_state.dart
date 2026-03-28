import 'dart:typed_data';

import 'package:equatable/equatable.dart';

import '../../../data/sgtp_client.dart';

class SetupState extends Equatable {
  final String serverAddress;
  final List<String> savedAddresses;
  final String? privateKeyPath;
  final Uint8List? privateKeyBytes;
  final Uint8List? myPublicKey;
  final List<String> whitelistPaths;
  final List<Uint8List> whitelistBytes;

  /// Maps ed25519 pubkey hex → human-readable nickname (from the .pub filename).
  /// e.g. "friend.pub" → nickname "friend"
  final Map<String, String> nicknames;

  final String roomUUID;
  final bool isLoading;
  final String? error;
  final SgtpConfig? connectionConfig;

  const SetupState({
    this.serverAddress = '',
    this.savedAddresses = const [],
    this.privateKeyPath,
    this.privateKeyBytes,
    this.myPublicKey,
    this.whitelistPaths = const [],
    this.whitelistBytes = const [],
    this.nicknames = const {},
    this.roomUUID = '',
    this.isLoading = false,
    this.error,
    this.connectionConfig,
  });

  bool get isReadyToConnect =>
      serverAddress.isNotEmpty && privateKeyBytes != null;

  SetupState copyWith({
    String? serverAddress,
    List<String>? savedAddresses,
    String? privateKeyPath,
    Uint8List? privateKeyBytes,
    Uint8List? myPublicKey,
    List<String>? whitelistPaths,
    List<Uint8List>? whitelistBytes,
    Map<String, String>? nicknames,
    String? roomUUID,
    bool? isLoading,
    String? error,
    SgtpConfig? connectionConfig,
    bool clearError = false,
    bool clearConnectionConfig = false,
    bool clearPrivateKey = false,
  }) {
    return SetupState(
      serverAddress: serverAddress ?? this.serverAddress,
      savedAddresses: savedAddresses ?? this.savedAddresses,
      privateKeyPath: clearPrivateKey ? null : (privateKeyPath ?? this.privateKeyPath),
      privateKeyBytes: clearPrivateKey ? null : (privateKeyBytes ?? this.privateKeyBytes),
      myPublicKey: clearPrivateKey ? null : (myPublicKey ?? this.myPublicKey),
      whitelistPaths: whitelistPaths ?? this.whitelistPaths,
      whitelistBytes: whitelistBytes ?? this.whitelistBytes,
      nicknames: nicknames ?? this.nicknames,
      roomUUID: roomUUID ?? this.roomUUID,
      isLoading: isLoading ?? this.isLoading,
      error: clearError ? null : (error ?? this.error),
      connectionConfig: clearConnectionConfig
          ? null
          : (connectionConfig ?? this.connectionConfig),
    );
  }

  @override
  List<Object?> get props => [
        serverAddress,
        savedAddresses,
        privateKeyPath,
        privateKeyBytes,
        myPublicKey,
        whitelistPaths,
        whitelistBytes,
        nicknames,
        roomUUID,
        isLoading,
        error,
        connectionConfig,
      ];
}
