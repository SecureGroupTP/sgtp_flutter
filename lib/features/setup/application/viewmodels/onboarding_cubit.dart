import 'dart:typed_data';

import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:sgtp_flutter/core/openssh_parser.dart';
import 'package:sgtp_flutter/core/sgtp_server_options.dart';
import 'package:sgtp_flutter/core/sgtp_transport.dart';
import 'package:sgtp_flutter/core/uuid_v7.dart';
import 'package:sgtp_flutter/features/settings/application/services/settings_management_service.dart';
import 'package:sgtp_flutter/features/setup/application/viewmodels/onboarding_view_state.dart';
import 'package:sgtp_flutter/features/setup/domain/entities/node.dart';

class OnboardingCubit extends Cubit<OnboardingViewState> {
  OnboardingCubit({
    required SettingsManagementService settings,
    required bool preferWebTransportOrder,
  })  : _settings = settings,
        _preferWebTransportOrder = preferWebTransportOrder,
        super(const OnboardingViewState());

  final SettingsManagementService _settings;
  final bool _preferWebTransportOrder;

  // ── Intent: Verify server ───────────────────────────────────────────────

  Future<void> verifyServer(String rawAddress) async {
    if (rawAddress.trim().isEmpty) {
      emit(OnboardingViewState(
        step: state.step,
        error: 'Enter server address',
        avatarBytes: state.avatarBytes,
      ));
      return;
    }
    emit(OnboardingViewState(
      step: state.step,
      isVerifying: true,
      avatarBytes: state.avatarBytes,
    ));
    try {
      final (host, explicitPort) = _parseHostPort(rawAddress);
      final result = await _settings.discoverServer(
        host,
        preferredPort: explicitPort,
      );
      final picked = _pickTransport(result.opts);
      final port = picked.$3 > 0 ? picked.$3 : result.port;

      emit(OnboardingViewState(
        step: 1,
        resolvedHost: host,
        resolvedDiscoveryPort: explicitPort,
        resolvedPort: port,
        resolvedTransport: picked.$1,
        resolvedTls: picked.$2,
        resolvedOptions: result.opts,
        avatarBytes: state.avatarBytes,
      ));
    } catch (e) {
      emit(OnboardingViewState(
        step: state.step,
        error: 'Server is not reachable: $e',
        avatarBytes: state.avatarBytes,
      ));
    }
  }

  void selectTransport(SgtpTransportFamily family) {
    final opts = state.resolvedOptions;
    if (opts == null) return;
    if (!opts.supports(family, tls: false) && !opts.supports(family, tls: true)) {
      return;
    }
    var useTls = state.resolvedTls;
    if (!opts.supports(family, tls: useTls)) {
      if (opts.supports(family, tls: true)) {
        useTls = true;
      } else if (opts.supports(family, tls: false)) {
        useTls = false;
      } else {
        return;
      }
    }
    final port = opts.portFor(family, tls: useTls);
    emit(OnboardingViewState(
      step: state.step,
      resolvedHost: state.resolvedHost,
      resolvedDiscoveryPort: state.resolvedDiscoveryPort,
      resolvedPort: port > 0 ? port : state.resolvedPort,
      resolvedTransport: family,
      resolvedTls: useTls,
      resolvedOptions: opts,
      avatarBytes: state.avatarBytes,
    ));
  }

  void setTls(bool value) {
    final opts = state.resolvedOptions;
    final transport = state.resolvedTransport;
    if (opts == null || transport == null) return;
    if (!opts.supports(transport, tls: value)) return;
    final port = opts.portFor(transport, tls: value);
    emit(OnboardingViewState(
      step: state.step,
      resolvedHost: state.resolvedHost,
      resolvedDiscoveryPort: state.resolvedDiscoveryPort,
      resolvedPort: port > 0 ? port : state.resolvedPort,
      resolvedTransport: transport,
      resolvedTls: value,
      resolvedOptions: opts,
      avatarBytes: state.avatarBytes,
    ));
  }

  // ── Intent: Pick avatar ─────────────────────────────────────────────────

  void setAvatar(Uint8List? bytes) {
    _avatarBytes = bytes;
    _buildState();
  }

  // ── Intent: Go back to server step ──────────────────────────────────────

  void goBackToServerStep() {
    emit(OnboardingViewState(
      step: 0,
      resolvedHost: state.resolvedHost,
      resolvedDiscoveryPort: state.resolvedDiscoveryPort,
      resolvedPort: state.resolvedPort,
      resolvedTransport: state.resolvedTransport,
      resolvedTls: state.resolvedTls,
      resolvedOptions: state.resolvedOptions,
      avatarBytes: state.avatarBytes,
    ));
  }

  // ── Intent: Finish onboarding ───────────────────────────────────────────

  Future<void> finish(String nickname, String rawUsername) async {
    final nick = nickname.trim();
    if (nick.isEmpty) {
      emit(OnboardingViewState(
        step: state.step,
        error: 'Nickname is required',
        resolvedHost: state.resolvedHost,
        resolvedDiscoveryPort: state.resolvedDiscoveryPort,
        resolvedPort: state.resolvedPort,
        resolvedTransport: state.resolvedTransport,
        resolvedTls: state.resolvedTls,
        resolvedOptions: state.resolvedOptions,
        avatarBytes: state.avatarBytes,
      ));
      return;
    }
    if (state.resolvedHost == null ||
        state.resolvedPort == null ||
        state.resolvedTransport == null) {
      emit(OnboardingViewState(
        step: state.step,
        error: 'Please verify server first',
        resolvedHost: state.resolvedHost,
        resolvedDiscoveryPort: state.resolvedDiscoveryPort,
        resolvedPort: state.resolvedPort,
        resolvedTransport: state.resolvedTransport,
        resolvedTls: state.resolvedTls,
        resolvedOptions: state.resolvedOptions,
        avatarBytes: state.avatarBytes,
      ));
      return;
    }

    emit(OnboardingViewState(
      step: state.step,
      isSaving: true,
      resolvedHost: state.resolvedHost,
      resolvedDiscoveryPort: state.resolvedDiscoveryPort,
      resolvedPort: state.resolvedPort,
      resolvedTransport: state.resolvedTransport,
      resolvedTls: state.resolvedTls,
      resolvedOptions: state.resolvedOptions,
      avatarBytes: state.avatarBytes,
    ));

    try {
      final accountId = await _ensureAccountId();
      final serverAddress = state.resolvedDiscoveryPort != null
          ? '${state.resolvedHost!}:${state.resolvedDiscoveryPort!}'
          : state.resolvedHost!;
      final username = _sanitizeUsername(rawUsername);

      await _settings.saveAddress(serverAddress);
      await _settings.loadOrCreateDeviceIdForNode(accountId);
      await _settings.saveUserNicknameForNode(accountId, nick);
      await _settings.saveUserUsernameForNode(accountId, username);
      if (_avatarBytes != null && _avatarBytes!.isNotEmpty) {
        await _settings.saveUserAvatarForNode(accountId, _avatarBytes!);
      } else {
        await _settings.clearUserAvatarForNode(accountId);
      }

      var nodes = await _settings.loadNodes();
      NodeConfig node;
      if (nodes.isNotEmpty) {
        node = nodes.first.copyWith(
          accountId: accountId,
          name: 'Connection',
          host: state.resolvedHost!,
          discoveryPort: state.resolvedDiscoveryPort,
          chatPort: state.resolvedPort!,
          voicePort: state.resolvedPort!,
          transport: state.resolvedTransport!,
          useTls: state.resolvedTls,
        );
      } else {
        node = NodeConfig(
          id: uuidBytesToHex(generateUUIDv7()),
          accountId: accountId,
          name: 'Connection',
          host: state.resolvedHost!,
          discoveryPort: state.resolvedDiscoveryPort,
          chatPort: state.resolvedPort!,
          voicePort: state.resolvedPort!,
          transport: state.resolvedTransport!,
          useTls: state.resolvedTls,
        );
      }
      await _settings.upsertNode(node);
      await _settings.setLastNodeId(node.id);
      await _settings.setLastAccountId(accountId);

      var savedKey = await _settings.loadPrivateKeyForNode(accountId);
      savedKey ??= await _settings.loadPrivateKey();
      if (savedKey == null) {
        await _settings.generatePrivateKey(accountId: accountId);
        savedKey = await _settings.loadPrivateKeyForNode(accountId);
      } else {
        parseOpenSshPrivateKey(savedKey.bytes);
      }
      if (savedKey == null) {
        throw const FormatException('No private key for account');
      }

      emit(OnboardingViewState(
        step: state.step,
        completed: true,
        resolvedHost: state.resolvedHost,
        resolvedDiscoveryPort: state.resolvedDiscoveryPort,
        resolvedPort: state.resolvedPort,
        resolvedTransport: state.resolvedTransport,
        resolvedTls: state.resolvedTls,
        resolvedOptions: state.resolvedOptions,
        avatarBytes: state.avatarBytes,
      ));
    } catch (e) {
      emit(OnboardingViewState(
        step: state.step,
        error: 'Failed to save onboarding data: $e',
        resolvedHost: state.resolvedHost,
        resolvedDiscoveryPort: state.resolvedDiscoveryPort,
        resolvedPort: state.resolvedPort,
        resolvedTransport: state.resolvedTransport,
        resolvedTls: state.resolvedTls,
        resolvedOptions: state.resolvedOptions,
        avatarBytes: state.avatarBytes,
      ));
    }
  }

  // ── Intent: Restore from backup ─────────────────────────────────────────

  Future<void> restoreFromBackup(Uint8List? backupBytes) async {
    if (backupBytes == null || backupBytes.isEmpty) {
      emit(OnboardingViewState(
        step: state.step,
        error: 'Selected backup file is empty',
        avatarBytes: state.avatarBytes,
      ));
      return;
    }
    emit(OnboardingViewState(
      step: state.step,
      isRestoring: true,
      avatarBytes: state.avatarBytes,
    ));
    try {
      await _settings.restoreFromBytes(backupBytes, merge: false);
      emit(OnboardingViewState(
        step: state.step,
        completed: true,
        avatarBytes: state.avatarBytes,
      ));
    } catch (e) {
      emit(OnboardingViewState(
        step: state.step,
        error: 'Failed to restore backup: $e',
        avatarBytes: state.avatarBytes,
      ));
    }
  }

  // ── Private ─────────────────────────────────────────────────────────────

  Uint8List? _avatarBytes;

  void _buildState() {
    emit(OnboardingViewState(
      step: state.step,
      isVerifying: state.isVerifying,
      isSaving: state.isSaving,
      isRestoring: state.isRestoring,
      error: state.error,
      resolvedHost: state.resolvedHost,
      resolvedDiscoveryPort: state.resolvedDiscoveryPort,
      resolvedPort: state.resolvedPort,
      resolvedTransport: state.resolvedTransport,
      resolvedTls: state.resolvedTls,
      resolvedOptions: state.resolvedOptions,
      avatarBytes: _avatarBytes,
    ));
  }

  Future<String> _ensureAccountId() async {
    var accountId = ((await _settings.loadLastAccountId()) ?? '').trim();
    if (accountId.isEmpty) {
      final all = await _settings.loadAccountIds();
      if (all.isNotEmpty) accountId = all.first.trim();
    }
    if (accountId.isEmpty) {
      accountId = uuidBytesToHex(generateUUIDv7());
      await _settings.upsertAccountId(accountId);
    }
    await _settings.setLastAccountId(accountId);
    return accountId;
  }

  String _sanitizeUsername(String raw) {
    final stripped = raw.trim().replaceFirst(RegExp(r'^@'), '');
    final sanitized = stripped.replaceAll(RegExp(r'[^A-Za-z0-9_]'), '');
    return sanitized.substring(0, sanitized.length.clamp(0, 32));
  }

  (SgtpTransportFamily family, bool tls, int port) _pickTransport(
      SgtpServerOptions opts) {
    final priority = _preferWebTransportOrder
        ? const <SgtpTransportFamily>[
            SgtpTransportFamily.websocket,
            SgtpTransportFamily.http,
          ]
        : const <SgtpTransportFamily>[
            SgtpTransportFamily.tcp,
            SgtpTransportFamily.websocket,
            SgtpTransportFamily.http,
          ];

    for (final family in priority) {
      if (opts.supports(family, tls: true)) {
        return (family, true, opts.portFor(family, tls: true));
      }
      if (opts.supports(family, tls: false)) {
        return (family, false, opts.portFor(family, tls: false));
      }
    }

    for (final family in SgtpTransportFamily.values) {
      if (opts.supports(family, tls: true)) {
        return (family, true, opts.portFor(family, tls: true));
      }
      if (opts.supports(family, tls: false)) {
        return (family, false, opts.portFor(family, tls: false));
      }
    }

    throw const FormatException('Server does not advertise any usable transport');
  }

  (String host, int? explicitPort) _parseHostPort(String raw) {
    final cleaned = raw
        .trim()
        .replaceAll(RegExp(r'^https?://', caseSensitive: false), '')
        .replaceAll(RegExp(r'^wss?://', caseSensitive: false), '')
        .trim();
    if (cleaned.isEmpty) {
      throw ArgumentError('Empty server address');
    }

    if (cleaned.startsWith('[')) {
      final end = cleaned.indexOf(']');
      if (end <= 1) throw ArgumentError('Invalid IPv6 address');
      final host = cleaned.substring(1, end);
      final rest = cleaned.substring(end + 1);
      final port =
          (rest.startsWith(':') ? int.tryParse(rest.substring(1)) : null);
      return (host, port);
    }

    final idx = cleaned.lastIndexOf(':');
    if (idx > 0 && idx < cleaned.length - 1) {
      final host = cleaned.substring(0, idx).trim();
      final port = int.tryParse(cleaned.substring(idx + 1).trim());
      return (host.isEmpty ? cleaned : host, port);
    }
    return (cleaned, null);
  }
}
