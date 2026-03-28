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
    on<SetupConnect>(_onConnect);
    on<SetupClearConnection>(_onClearConnection);
  }

  // ── Load saved state on startup ──────────────────────────────────────────

  Future<void> _onLoadData(SetupLoadData event, Emitter<SetupState> emit) async {
    final addresses = await _settings.getSavedAddresses();
    final last      = await _settings.getLastAddress();

    // Restore private key
    final savedKey = await _settings.loadPrivateKey();
    Uint8List? privKeyBytes;
    String?    privKeyPath;
    Uint8List? myPubKey;

    if (savedKey != null) {
      try {
        final parsed = parseOpenSshPrivateKey(savedKey.bytes);
        privKeyBytes = savedKey.bytes;
        privKeyPath  = savedKey.path;
        myPubKey     = parsed.publicKey;
      } catch (_) {
        await _settings.clearPrivateKey();
      }
    }

    // Restore whitelist
    final savedWl = await _settings.loadWhitelist();
    List<Uint8List> wlBytes = [];
    List<String>    wlPaths = [];
    Map<String, String> nicknames = {};

    if (savedWl != null) {
      wlBytes    = savedWl.bytesList;
      wlPaths    = savedWl.paths;
      nicknames  = _buildNicknames(wlBytes, wlPaths);
    }

    emit(state.copyWith(
      savedAddresses: addresses,
      serverAddress:  last ?? '',
      privateKeyBytes: privKeyBytes,
      privateKeyPath:  privKeyPath,
      myPublicKey:     myPubKey,
      whitelistBytes:  wlBytes,
      whitelistPaths:  wlPaths,
      nicknames:       nicknames,
      clearError: true,
    ));
  }

  // ── Server address ────────────────────────────────────────────────────────

  void _onServerAddressChanged(
      SetupServerAddressChanged event, Emitter<SetupState> emit) {
    emit(state.copyWith(serverAddress: event.address, clearError: true));
  }

  // ── Private key ───────────────────────────────────────────────────────────

  Future<void> _onPickPrivateKey(
      SetupPickPrivateKey event, Emitter<SetupState> emit) async {
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
      await _settings.savePrivateKey(bytes, file.name);

      emit(state.copyWith(
        privateKeyPath:  file.name,
        privateKeyBytes: bytes,
        myPublicKey:     parsed.publicKey,
        clearError: true,
      ));
    } catch (e) {
      emit(state.copyWith(error: 'Invalid private key file: $e'));
    }
  }

  // ── Whitelist: folder ─────────────────────────────────────────────────────

  Future<void> _onPickWhitelistFolder(
      SetupPickWhitelistFolder event, Emitter<SetupState> emit) async {
    try {
      final dirPath = await FilePicker.platform.getDirectoryPath();
      if (dirPath == null) return;

      final dir      = Directory(dirPath);
      final paths    = <String>[];
      final bytesList = <Uint8List>[];

      await for (final entity in dir.list(recursive: false)) {
        if (entity is File) {
          try {
            final bytes  = await entity.readAsBytes();
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
          error: 'No valid ed25519 public keys found in "$dirPath"',
        ));
        return;
      }

      await _settings.saveWhitelist(bytesList, paths);
      final nicknames = _buildNicknames(bytesList, paths);

      emit(state.copyWith(
        whitelistPaths:  paths,
        whitelistBytes:  bytesList,
        nicknames:       nicknames,
        clearError: true,
      ));
    } catch (e) {
      emit(state.copyWith(error: 'Failed to load whitelist folder: $e'));
    }
  }

  // ── Whitelist: individual files ───────────────────────────────────────────

  Future<void> _onPickWhitelistFiles(
      SetupPickWhitelistFiles event, Emitter<SetupState> emit) async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.any,
        withData: true,
        allowMultiple: true,
      );
      if (result == null || result.files.isEmpty) return;

      final paths    = <String>[];
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

      await _settings.saveWhitelist(bytesList, paths);
      final nicknames = _buildNicknames(bytesList, paths);

      emit(state.copyWith(
        whitelistPaths:  paths,
        whitelistBytes:  bytesList,
        nicknames:       nicknames,
        clearError: true,
      ));
    } catch (e) {
      emit(state.copyWith(error: 'Failed to load whitelist files: $e'));
    }
  }

  // ── Connect ───────────────────────────────────────────────────────────────

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

      final config = SgtpConfig(
        serverAddr:      state.serverAddress.trim(),
        roomUUID:        Uint8List(16),
        identityKeyPair: keyPair,
        myPublicKey:     parsed.publicKey,
        whitelist:       whitelist,
      );

      await _settings.saveAddress(state.serverAddress.trim());
      final updated = await _settings.getSavedAddresses();

      emit(state.copyWith(
        isLoading:       false,
        savedAddresses:  updated,
        connectionConfig: config,
        clearError: true,
      ));
    } catch (e) {
      emit(state.copyWith(isLoading: false, error: 'Setup error: $e'));
    }
  }

  // ── Clear connection config after navigation ──────────────────────────────

  void _onClearConnection(
      SetupClearConnection event, Emitter<SetupState> emit) {
    emit(state.copyWith(clearConnectionConfig: true));
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  /// Derives nicknames from whitelist file names.
  /// "friend.pub" → "friend", "alice" → "alice".
  Map<String, String> _buildNicknames(
      List<Uint8List> bytesList, List<String> paths) {
    final result = <String, String>{};
    for (var i = 0; i < bytesList.length; i++) {
      final hex = bytesList[i]
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
      var name = paths[i];
      if (name.toLowerCase().endsWith('.pub')) {
        name = name.substring(0, name.length - 4);
      }
      result[hex] = name;
    }
    return result;
  }

}
