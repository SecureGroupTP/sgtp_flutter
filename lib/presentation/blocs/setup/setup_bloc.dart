import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/crypto/ed25519_utils.dart';
import '../../../core/openssh_parser.dart';
import '../../../data/repositories/settings_repository.dart';
import '../../../data/sgtp_client.dart';
import 'setup_event.dart';
import 'setup_state.dart';

class SetupBloc extends Bloc<SetupEvent, SetupState> {
  final SettingsRepository _settings;

  SetupBloc({SettingsRepository? settings})
      : _settings = settings ?? SettingsRepository(),
        super(const SetupState()) {
    on<SetupLoadData>(_onLoadData);
    on<SetupServerAddressChanged>(_onServerAddressChanged);
    on<SetupPickPrivateKey>(_onPickPrivateKey);
    on<SetupPickWhitelistFiles>(_onPickWhitelistFiles);
    on<SetupRoomUUIDChanged>(_onRoomUUIDChanged);
    on<SetupConnect>(_onConnect);
  }

  Future<void> _onLoadData(SetupLoadData event, Emitter<SetupState> emit) async {
    final addresses = await _settings.getSavedAddresses();
    final last = await _settings.getLastAddress();
    emit(state.copyWith(
      savedAddresses: addresses,
      serverAddress: last ?? '',
      clearError: true,
    ));
  }

  void _onServerAddressChanged(
    SetupServerAddressChanged event,
    Emitter<SetupState> emit,
  ) {
    emit(state.copyWith(serverAddress: event.address, clearError: true));
  }

  Future<void> _onPickPrivateKey(
    SetupPickPrivateKey event,
    Emitter<SetupState> emit,
  ) async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.any,
        withData: true,
        allowMultiple: false,
      );
      if (result == null || result.files.isEmpty) return;
      final file = result.files.first;
      final bytes = file.bytes;
      if (bytes == null) {
        emit(state.copyWith(error: 'Could not read key file'));
        return;
      }

      // Parse OpenSSH private key
      final parsed = parseOpenSshPrivateKey(bytes);
      final pubKey = parsed.publicKey;

      emit(state.copyWith(
        privateKeyPath: file.name,
        privateKeyBytes: bytes,
        myPublicKey: pubKey,
        clearError: true,
      ));
    } catch (e) {
      emit(state.copyWith(error: 'Invalid private key file: $e'));
    }
  }

  Future<void> _onPickWhitelistFiles(
    SetupPickWhitelistFiles event,
    Emitter<SetupState> emit,
  ) async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.any,
        withData: true,
        allowMultiple: true,
      );
      if (result == null || result.files.isEmpty) return;

      final paths = <String>[];
      final bytesList = <Uint8List>[];

      for (final file in result.files) {
        final bytes = file.bytes;
        if (bytes == null) continue;
        // Try to parse as public key
        final pubKey = tryParsePublicKeyFile(bytes);
        if (pubKey != null) {
          paths.add(file.name);
          bytesList.add(pubKey);
        }
      }

      if (bytesList.isEmpty) {
        emit(state.copyWith(
          error: 'No valid ed25519 public keys found in selected files',
        ));
        return;
      }

      emit(state.copyWith(
        whitelistPaths: paths,
        whitelistBytes: bytesList,
        clearError: true,
      ));
    } catch (e) {
      emit(state.copyWith(error: 'Failed to load whitelist files: $e'));
    }
  }

  void _onRoomUUIDChanged(SetupRoomUUIDChanged event, Emitter<SetupState> emit) {
    emit(state.copyWith(roomUUID: event.uuid, clearError: true));
  }

  Future<void> _onConnect(SetupConnect event, Emitter<SetupState> emit) async {
    if (!state.isReadyToConnect) {
      emit(state.copyWith(error: 'Server address and private key are required'));
      return;
    }

    emit(state.copyWith(isLoading: true, clearError: true));

    try {
      // Parse private key
      final privKeyBytes = state.privateKeyBytes!;
      final parsed = parseOpenSshPrivateKey(privKeyBytes);
      final keyPair = makeKeyPair(parsed.seed, parsed.publicKey);

      // Build whitelist: set of hex-encoded ed25519 public keys
      final whitelist = state.whitelistBytes
          .map((b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join())
          .toSet();

      // Parse room UUID
      Uint8List roomUUID;
      final uuidStr = state.roomUUID.trim().replaceAll('-', '');
      if (uuidStr.isEmpty) {
        roomUUID = Uint8List(16); // zeros = create new
      } else {
        try {
          roomUUID = _hexToBytes(uuidStr);
        } catch (_) {
          emit(state.copyWith(
            isLoading: false,
            error: 'Invalid room UUID format',
          ));
          return;
        }
      }

      final config = SgtpConfig(
        serverAddr: state.serverAddress.trim(),
        roomUUID: roomUUID,
        identityKeyPair: keyPair,
        myPublicKey: parsed.publicKey,
        whitelist: whitelist,
      );

      // Save server address
      await _settings.saveAddress(state.serverAddress.trim());
      final updated = await _settings.getSavedAddresses();

      emit(state.copyWith(
        isLoading: false,
        savedAddresses: updated,
        connectionConfig: config,
        clearError: true,
      ));
    } catch (e) {
      emit(state.copyWith(
        isLoading: false,
        error: 'Setup error: $e',
      ));
    }
  }

  Uint8List _hexToBytes(String hex) {
    if (hex.length != 32) throw FormatException('UUID must be 32 hex chars');
    final result = Uint8List(16);
    for (var i = 0; i < 16; i++) {
      result[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return result;
  }
}
