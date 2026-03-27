import 'dart:typed_data';

import 'package:equatable/equatable.dart';

import '../../../data/sgtp_client.dart';

class SetupState extends Equatable {
  final String serverAddress;
  final List<String> savedAddresses;
  final String? privateKeyPath;
  final Uint8List? privateKeyBytes;
  final Uint8List? myPublicKey; // derived from private key
  final List<String> whitelistPaths;
  final List<Uint8List> whitelistBytes;
  final String roomUUID;
  final bool isLoading;
  final String? error;
  final SgtpConfig? connectionConfig; // set when ready to connect

  const SetupState({
    this.serverAddress = '',
    this.savedAddresses = const [],
    this.privateKeyPath,
    this.privateKeyBytes,
    this.myPublicKey,
    this.whitelistPaths = const [],
    this.whitelistBytes = const [],
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
      roomUUID: roomUUID ?? this.roomUUID,
      isLoading: isLoading ?? this.isLoading,
      error: clearError ? null : (error ?? this.error),
      connectionConfig: clearConnectionConfig ? null : (connectionConfig ?? this.connectionConfig),
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
        roomUUID,
        isLoading,
        error,
        connectionConfig,
      ];
}
