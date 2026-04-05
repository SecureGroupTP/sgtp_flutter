import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:image_picker/image_picker.dart';

import 'package:sgtp_flutter/core/openssh_parser.dart';
import 'package:sgtp_flutter/core/sgtp_server_options.dart';
import 'package:sgtp_flutter/core/sgtp_transport.dart';
import 'package:sgtp_flutter/core/uuid_v7.dart';
import 'package:sgtp_flutter/features/settings/application/services/settings_management_service.dart';
import 'package:sgtp_flutter/features/setup/application/models/setup_models.dart';
import 'package:sgtp_flutter/features/setup/domain/entities/node.dart';

class OnboardingPage extends StatefulWidget {
  const OnboardingPage({super.key});

  @override
  State<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends State<OnboardingPage> {
  late final SettingsManagementService _settings;
  final _serverCtrl = TextEditingController();
  final _nicknameCtrl = TextEditingController(text: 'Account');
  final _usernameCtrl = TextEditingController();
  final _picker = ImagePicker();

  int _step = 0;
  bool _verifying = false;
  bool _saving = false;
  bool _restoring = false;
  String? _error;

  String? _resolvedHost;
  int? _resolvedPort;
  SgtpTransportFamily? _resolvedTransport;
  bool _resolvedTls = false;
  SgtpServerOptions? _resolvedOptions;

  Uint8List? _avatarBytes;

  @override
  void initState() {
    super.initState();
    _settings = context.read<SettingsManagementService>();
  }

  @override
  void dispose() {
    _serverCtrl.dispose();
    _nicknameCtrl.dispose();
    _usernameCtrl.dispose();
    super.dispose();
  }

  Future<void> _verifyServer() async {
    final raw = _serverCtrl.text.trim();
    if (raw.isEmpty) {
      setState(() => _error = 'Enter server address');
      return;
    }
    setState(() {
      _verifying = true;
      _error = null;
    });
    try {
      final (host, explicitPort) = _parseHostPort(raw);
      final result = await _settings.discoverServer(host);
      final picked = _pickTransport(result.opts);
      final port = explicitPort ?? picked.$3;

      if (!mounted) return;
      setState(() {
        _resolvedHost = host;
        _resolvedPort = port;
        _resolvedTransport = picked.$1;
        _resolvedTls = picked.$2;
        _resolvedOptions = result.opts;
        _step = 1;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Server is not reachable: $e');
    } finally {
      if (mounted) {
        setState(() => _verifying = false);
      }
    }
  }

  (SgtpTransportFamily family, bool tls, int port) _pickTransport(
      SgtpServerOptions opts) {
    if (opts.supports(SgtpTransportFamily.tcp, tls: true)) {
      return (
        SgtpTransportFamily.tcp,
        true,
        opts.portFor(SgtpTransportFamily.tcp, tls: true)
      );
    }
    if (opts.supports(SgtpTransportFamily.tcp, tls: false)) {
      return (
        SgtpTransportFamily.tcp,
        false,
        opts.portFor(SgtpTransportFamily.tcp, tls: false)
      );
    }
    if (opts.supports(SgtpTransportFamily.websocket, tls: true)) {
      return (
        SgtpTransportFamily.websocket,
        true,
        opts.portFor(SgtpTransportFamily.websocket, tls: true)
      );
    }
    if (opts.supports(SgtpTransportFamily.websocket, tls: false)) {
      return (
        SgtpTransportFamily.websocket,
        false,
        opts.portFor(SgtpTransportFamily.websocket, tls: false)
      );
    }
    if (opts.supports(SgtpTransportFamily.http, tls: true)) {
      return (
        SgtpTransportFamily.http,
        true,
        opts.portFor(SgtpTransportFamily.http, tls: true)
      );
    }
    return (
      SgtpTransportFamily.http,
      false,
      opts.portFor(SgtpTransportFamily.http, tls: false)
    );
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

  String _sanitizeUsername(String raw) {
    final stripped = raw.trim().replaceFirst(RegExp(r'^@'), '');
    final sanitized = stripped.replaceAll(RegExp(r'[^A-Za-z0-9_]'), '');
    return sanitized.substring(0, sanitized.length.clamp(0, 32));
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

  Future<void> _finish() async {
    final nick = _nicknameCtrl.text.trim();
    if (nick.isEmpty) {
      setState(() => _error = 'Nickname is required');
      return;
    }
    if (_resolvedHost == null ||
        _resolvedPort == null ||
        _resolvedTransport == null) {
      setState(() => _error = 'Please verify server first');
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });

    try {
      final accountId = await _ensureAccountId();
      final serverAddress = '${_resolvedHost!}:${_resolvedPort!}';
      final username = _sanitizeUsername(_usernameCtrl.text);

      await _settings.saveAddress(serverAddress);
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
          host: _resolvedHost!,
          chatPort: _resolvedPort!,
          voicePort: _resolvedPort!,
          transport: _resolvedTransport!,
          useTls: _resolvedTls,
        );
      } else {
        node = NodeConfig(
          id: uuidBytesToHex(generateUUIDv7()),
          accountId: accountId,
          name: 'Connection',
          host: _resolvedHost!,
          chatPort: _resolvedPort!,
          voicePort: _resolvedPort!,
          transport: _resolvedTransport!,
          useTls: _resolvedTls,
        );
      }
      await _settings.upsertNode(node);
      await _settings.setLastNodeId(node.id);
      await _settings.setLastAccountId(accountId);
      if (_resolvedOptions != null) {
        await _settings.saveNodeServerOptions(node.id, _resolvedOptions!);
      }

      var savedKey = await _settings.loadPrivateKeyForNode(accountId);
      savedKey ??= await _settings.loadPrivateKey();
      if (savedKey == null) {
        await _settings.generatePrivateKey(accountId: accountId);
      } else {
        // validate key once to ensure the startup screen won't fail loop
        parseOpenSshPrivateKey(savedKey.bytes);
      }

      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Failed to save onboarding data: $e');
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  Future<void> _pickAvatar() async {
    Uint8List? bytes;

    final file = await _picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 512,
      maxHeight: 512,
      imageQuality: 80,
    );
    if (file != null) {
      bytes = await file.readAsBytes();
    }

    if ((bytes == null || bytes.isEmpty) && kIsWeb) {
      final picked = await FilePicker.platform.pickFiles(
        type: FileType.image,
        withData: true,
      );
      final data = (picked != null && picked.files.isNotEmpty)
          ? picked.files.first.bytes
          : null;
      if (data != null && data.isNotEmpty) {
        bytes = data;
      }
    }

    if (bytes == null || bytes.isEmpty) return;
    if (!mounted) return;
    setState(() => _avatarBytes = bytes);
  }

  Future<void> _restoreFromBackup() async {
    setState(() {
      _restoring = true;
      _error = null;
    });
    try {
      final picked = await FilePicker.platform.pickFiles(
        allowMultiple: false,
        withData: true,
        type: FileType.custom,
        allowedExtensions: const ['sgtpbackup', 'json'],
      );
      if (picked == null || picked.files.isEmpty) return;
      final bytes = picked.files.first.bytes;
      if (bytes == null || bytes.isEmpty) {
        setState(() => _error = 'Selected backup file is empty');
        return;
      }

      await _settings.restoreFromBytes(bytes, merge: false);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Backup restored')),
      );
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Failed to restore backup: $e');
    } finally {
      if (mounted) setState(() => _restoring = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 12),
              Text(
                _step == 0 ? 'Choose Server' : 'Set Up Profile',
                style: const TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                _step == 0
                    ? 'First, connect to a working server.'
                    : 'Now set your profile. Username is optional.',
                style: const TextStyle(fontSize: 14, color: Colors.white70),
              ),
              const SizedBox(height: 24),
              Expanded(
                child: _step == 0 ? _buildServerStep() : _buildProfileStep(),
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(_error!, style: const TextStyle(color: Colors.redAccent)),
              ],
              const SizedBox(height: 12),
              FilledButton(
                onPressed: _verifying || _saving || _restoring
                    ? null
                    : (_step == 0 ? _verifyServer : _finish),
                child: _verifying || _saving
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(_step == 0 ? 'Continue' : 'Start'),
              ),
              if (_step == 0) ...[
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: _verifying || _saving || _restoring
                      ? null
                      : _restoreFromBackup,
                  icon: _restoring
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.restore),
                  label: const Text('Restore from backup'),
                ),
              ],
              if (_step == 1) ...[
                const SizedBox(height: 8),
                TextButton(
                  onPressed: _verifying || _saving
                      ? null
                      : () => setState(() => _step = 0),
                  child: const Text('Back to server'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildServerStep() {
    final available = _resolvedOptions?.availableLabels().join(', ');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _serverCtrl,
          decoration: const InputDecoration(
            labelText: 'Server address',
            hintText: 'example.com or example.com:443',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        if (available != null && available.isNotEmpty)
          Text(
            'Detected transports: $available',
            style: const TextStyle(color: Colors.white70),
          ),
      ],
    );
  }

  Widget _buildProfileStep() {
    return ListView(
      children: [
        if (_resolvedHost != null && _resolvedPort != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              'Server: $_resolvedHost:$_resolvedPort',
              style: const TextStyle(color: Colors.white70),
            ),
          ),
        Center(
          child: GestureDetector(
            onTap: _pickAvatar,
            child: CircleAvatar(
              radius: 46,
              backgroundImage:
                  _avatarBytes != null ? MemoryImage(_avatarBytes!) : null,
              child: _avatarBytes == null
                  ? const Icon(Icons.add_a_photo_outlined, size: 28)
                  : null,
            ),
          ),
        ),
        const SizedBox(height: 20),
        TextField(
          controller: _nicknameCtrl,
          decoration: const InputDecoration(
            labelText: 'Nickname',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _usernameCtrl,
          decoration: const InputDecoration(
            labelText: 'Username (optional)',
            hintText: '@alice',
            border: OutlineInputBorder(),
          ),
        ),
      ],
    );
  }
}
