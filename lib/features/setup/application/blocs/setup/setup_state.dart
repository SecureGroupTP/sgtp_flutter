import 'dart:typed_data';

import 'package:equatable/equatable.dart';

import 'package:sgtp_flutter/core/sgtp_server_options.dart';
import 'package:sgtp_flutter/core/sgtp_transport.dart';
import 'package:sgtp_flutter/features/messaging/application/services/messaging_data_access.dart';

class SetupState extends Equatable {
  final String serverAddress;
  final List<String> savedAddresses;
  final String nodeId;
  final SgtpTransportFamily transport;
  final bool useTls;
  final SgtpServerOptions? serverOptions;
  final bool isOptionsLoading;
  final String? optionsError;
  final String? privateKeyPath;
  final Uint8List? privateKeyBytes;
  final Uint8List? myPublicKey;
  final List<String> whitelistPaths;
  final List<Uint8List> whitelistBytes;

  /// Maps ed25519 pubkey hex → human-readable nickname (from the .pub filename).
  /// e.g. "friend.pub" → nickname "friend"
  final Map<String, String> nicknames;

  final bool isLoading;
  final String? error;
  final SgtpConfig? connectionConfig;

  const SetupState({
    this.serverAddress = '',
    this.savedAddresses = const [],
    this.nodeId = '',
    this.transport = SgtpTransportFamily.tcp,
    this.useTls = false,
    this.serverOptions,
    this.isOptionsLoading = false,
    this.optionsError,
    this.privateKeyPath,
    this.privateKeyBytes,
    this.myPublicKey,
    this.whitelistPaths = const [],
    this.whitelistBytes = const [],
    this.nicknames = const {},
    this.isLoading = false,
    this.error,
    this.connectionConfig,
  });

  bool get isReadyToConnect =>
      serverAddress.isNotEmpty && privateKeyBytes != null;

  SetupState copyWith({
    String? serverAddress,
    List<String>? savedAddresses,
    String? nodeId,
    SgtpTransportFamily? transport,
    bool? useTls,
    SgtpServerOptions? serverOptions,
    bool? isOptionsLoading,
    String? optionsError,
    String? privateKeyPath,
    Uint8List? privateKeyBytes,
    Uint8List? myPublicKey,
    List<String>? whitelistPaths,
    List<Uint8List>? whitelistBytes,
    Map<String, String>? nicknames,
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
      nodeId: nodeId ?? this.nodeId,
      transport: transport ?? this.transport,
      useTls: useTls ?? this.useTls,
      serverOptions: serverOptions ?? this.serverOptions,
      isOptionsLoading: isOptionsLoading ?? this.isOptionsLoading,
      optionsError: optionsError ?? this.optionsError,
      privateKeyPath: clearPrivateKey ? null : (privateKeyPath ?? this.privateKeyPath),
      privateKeyBytes: clearPrivateKey ? null : (privateKeyBytes ?? this.privateKeyBytes),
      myPublicKey: clearPrivateKey ? null : (myPublicKey ?? this.myPublicKey),
      whitelistPaths: whitelistPaths ?? this.whitelistPaths,
      whitelistBytes: whitelistBytes ?? this.whitelistBytes,
      nicknames: nicknames ?? this.nicknames,
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
        nodeId,
        transport,
        useTls,
        serverOptions,
        isOptionsLoading,
        optionsError,
        privateKeyPath,
        privateKeyBytes,
        myPublicKey,
        whitelistPaths,
        whitelistBytes,
        nicknames,
        isLoading,
        error,
        connectionConfig,
      ];
}
