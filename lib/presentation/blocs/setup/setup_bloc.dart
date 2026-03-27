import 'dart:io';
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
    on<SetupPickWhitelistFolder>(_onPickWhitelistFolder);
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

  void _onServerAddressChanged(SetupServerAddressChanged event, Emitter<SetupState> emit) {
    emit(state.copyWith(serverAddress: event.address, clearError: true));
  }

  Future<void> _onPickPrivateKey(SetupPickPrivateKey event, Emitter<SetupState> emit) async {
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

      final parsed = parseOpenSshPrivateKey(bytes);
      emit(state.copyWith(
        privateKeyPath: file.name,
        privateKeyBytes: bytes,
        myPublicKey: parsed.publicKey,
        clearError: true,
      ));
    } catch (e) {
      emit(state.copyWith(error: 'Invalid private key file: $e'));
    }
  }

  /// Pick a FOLDER containing whitelist .pub files.
  Future<void> _onPickWhitelistFolder(
    SetupPickWhitelistFolder event,
    Emitter<SetupState> emit,
  ) async {
    try {
      final dirPath = await FilePicker.platform.getDirectoryPath();
      if (dirPath == null) return;

      final dir = Directory(dirPath);
      final paths = <String>[];
      final bytesList = <Uint8List>[];

      await for (final entity in dir.list(recursive: false)) {
        if (entity is File) {
          try {
            final bytes = await entity.readAsBytes();
            final pubKey = tryParsePublicKeyFile(bytes);
            if (pubKey != null) {
              paths.add(entity.path.split(Platform.pathSeparator).last);
              bytesList.add(pubKey);
            }
          } catch (_) {}
        }
      }

      if (bytesList.isEmpty) {
        emit(state.copyWith(
          error: 'No valid ed25519 public keys found in folder "$dirPath"',
        ));
        return;
      }

      emit(state.copyWith(
        whitelistPaths: paths,
        whitelistBytes: bytesList,
        clearError: true,
      ));
    } catch (e) {
      emit(state.copyWith(error: 'Failed to load whitelist folder: $e'));
    }
  }

  /// Pick individual whitelist files.
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
      final privKeyBytes = state.privateKeyBytes!;
      final parsed = parseOpenSshPrivateKey(privKeyBytes);
      final keyPair = makeKeyPair(parsed.seed, parsed.publicKey);

      final whitelist = state.whitelistBytes
          .map((b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join())
          .toSet();

      Uint8List roomUUID;
      final uuidStr = state.roomUUID.trim().replaceAll('-', '');
      if (uuidStr.isEmpty) {
        roomUUID = Uint8List(16); // zeros = create new random room
      } else {
        try {
          if (uuidStr.length != 32) {
            throw const FormatException('UUID must be 32 hex chars (without dashes)');
          }
          roomUUID = _hexToBytes(uuidStr);
        } catch (e) {
          emit(state.copyWith(
            isLoading: false,
            error: 'Invalid room UUID format: $e',
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

      await _settings.saveAddress(state.serverAddress.trim());
      final updated = await _settings.getSavedAddresses();

      emit(state.copyWith(
        isLoading: false,
        savedAddresses: updated,
        connectionConfig: config,
        clearError: true,
      ));
    } catch (e) {
      emit(state.copyWith(isLoading: false, error: 'Setup error: $e'));
    }
  }

  Uint8List _hexToBytes(String hex) {
    final result = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < result.length; i++) {
      result[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return result;
  }
}
