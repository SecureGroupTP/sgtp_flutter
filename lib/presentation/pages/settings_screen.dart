import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/app_theme.dart';
import '../../core/crypto/ed25519_utils.dart';
import '../../core/interaction_prefs.dart';
import '../../core/openssh_parser.dart';
import '../../core/qr_data.dart';
import '../../core/uuid_v7.dart';
import '../../data/repositories/settings_repository.dart';
import '../../data/sgtp_client.dart';
import '../../domain/entities/node.dart';
import '../../core/app_logger.dart';
import '../../core/constants.dart';
import '../widgets/pretty_qr_share_panel.dart';
import 'logs_screen.dart';
import 'package:url_launcher/url_launcher.dart';

typedef ConfigChangedCallback = void Function(
    SgtpConfig config, Map<String, String> nicknames, String serverAddress);

typedef UserAvatarChangedCallback = void Function(Uint8List? avatar);

class SettingsScreen extends StatefulWidget {
  final SgtpConfig? initialConfig;
  final Map<String, String>? initialNicknames;
  final ConfigChangedCallback? onConfigChanged;
  final UserAvatarChangedCallback? onUserAvatarChanged;
  final Uint8List? currentUserAvatar;

  const SettingsScreen({
    super.key,
    this.initialConfig,
    this.initialNicknames,
    this.onConfigChanged,
    this.onUserAvatarChanged,
    this.currentUserAvatar,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _settings = SettingsRepository();
  final _serverCtrl = TextEditingController();
  final _nicknameCtrl = TextEditingController();

  String? _privateKeyPath;
  Uint8List? _privateKeyBytes;
  Uint8List? _myPublicKey;

  List<WhitelistEntry> _wlEntries = [];
  Map<String, String> _nicknames = {};

  Uint8List? _userAvatar;
  String _nickname = '';

  bool _isLoading = false;
  bool _isGenerating = false;
  String? _error;

  /// Ping interval in seconds. Saved via SettingsRepository.
  int _pingIntervalSeconds = 30;
  bool _compressFiles = false;
  bool _compressPhotos = false;
  bool _compressVideos = false;
  int _mediaChunkSizeBytes = SgtpConstants.defaultMediaChunkSize;

  // Interaction preferences (Fix 7)
  String _doubleTapDesktop = 'react'; // 'react' | 'reply'
  bool _swipeToReply = true;
  bool _longPressMenu = true;

  // Nodes
  List<NodeConfig> _nodes = const [];
  bool _nodesLoading = true;

  @override
  void initState() {
    super.initState();
    _userAvatar = widget.currentUserAvatar;
    _loadFromConfig();
  }

  void _loadFromConfig() {
    final cfg = widget.initialConfig;
    if (cfg != null) {
      _serverCtrl.text = cfg.serverAddr;
      _myPublicKey = cfg.myPublicKey;
    }
    _nicknames = Map.from(widget.initialNicknames ?? {});
    _loadFromDisk();
  }

  Future<void> _loadFromDisk() async {
    final savedKey = await _settings.loadPrivateKey();
    if (savedKey != null) {
      try {
        final parsed = parseOpenSshPrivateKey(savedKey.bytes);
        setState(() {
          _privateKeyBytes = savedKey.bytes;
          _privateKeyPath = savedKey.name;
          _myPublicKey = parsed.publicKey;
        });
      } catch (_) {}
    }

    final entries = await _settings.loadWhitelistEntries();
    if (entries.isNotEmpty) {
      setState(() {
        _wlEntries = entries;
        _nicknames = _buildNicknames(entries);
      });
    }

    final lastAddr = await _settings.getLastAddress();
    if (lastAddr != null && _serverCtrl.text.isEmpty) {
      setState(() => _serverCtrl.text = lastAddr);
    }

    // Load nodes (no node details shown outside Settings).
    final nodes = await _settings.loadNodes();
    final preferredNode = await _settings.loadPreferredNode();
    if (mounted) {
      setState(() {
        _nodes = nodes;
        _nodesLoading = false;
        if (preferredNode != null) {
          _serverCtrl.text = preferredNode.chatAddress;
        }
      });
    }

    final avatar = await _settings.loadUserAvatar();
    if (avatar != null) setState(() => _userAvatar = avatar);
    final mediaSettings = await _settings.loadMediaTransferSettings();

    // Load persisted prefs (nickname + interaction)
    final prefs = await SharedPreferences.getInstance();
    final savedNickname = prefs.getString('sgtp_user_nickname') ?? '';
    setState(() {
      _nickname = savedNickname;
      _nicknameCtrl.text = savedNickname;
      _pingIntervalSeconds = prefs.getInt('sgtp_ping_interval') ?? 30;
      _compressFiles = mediaSettings.compressFiles;
      _compressPhotos = mediaSettings.compressPhotos;
      _compressVideos = mediaSettings.compressVideos;
      _mediaChunkSizeBytes = mediaSettings.mediaChunkSizeBytes;
      _doubleTapDesktop =
          prefs.getString('iprefs_doubletap_desktop') ?? 'react';
      _swipeToReply = prefs.getBool('iprefs_swipe_to_reply') ?? true;
      _longPressMenu = prefs.getBool('iprefs_longpress_menu') ?? true;
    });
    // Sync singleton
    InteractionPrefs.doubleTapDesktop = _doubleTapDesktop;
    InteractionPrefs.swipeToReply = _swipeToReply;
    InteractionPrefs.longPressShowsMenu = _longPressMenu;
  }

  @override
  void dispose() {
    _serverCtrl.dispose();
    _nicknameCtrl.dispose();
    super.dispose();
  }

  Map<String, String> _buildNicknames(List<WhitelistEntry> entries) {
    final result = <String, String>{};
    for (final e in entries) {
      result[e.hexKey] = e.name;
    }
    return result;
  }

  // ── Private key: browse ──────────────────────────────────────────────────

  Future<void> _pickPrivateKey() async {
    try {
      final result = await FilePicker.platform
          .pickFiles(type: FileType.any, withData: true, allowMultiple: false);
      if (result == null || result.files.isEmpty) return;
      final file = result.files.first;
      final bytes = file.bytes;
      if (bytes == null) {
        _setError('Could not read key file');
        return;
      }
      final parsed = parseOpenSshPrivateKey(bytes);
      await _settings.savePrivateKey(bytes, file.name);
      setState(() {
        _privateKeyBytes = bytes;
        _privateKeyPath = file.name;
        _myPublicKey = parsed.publicKey;
        _error = null;
      });
      _tryApplyConfig();
    } catch (e) {
      _setError('Invalid private key: $e');
    }
  }

  // ── Private key: generate ────────────────────────────────────────────────

  Future<void> _generatePrivateKey() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Generate New Key?'),
        content: const Text(
            'This will create a new Ed25519 identity key and save it to the sgtp directory.\n\n'
            'Your old key will be replaced. Peers that trusted your old key will need to add the new one to their whitelist.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.orange),
            child: const Text('Generate'),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    setState(() => _isGenerating = true);
    try {
      // Generate new Ed25519 key pair
      final algorithm = Ed25519();
      final keyPair = await algorithm.newKeyPair();
      final pubKey = await keyPair.extractPublicKey();
      final privBytes = await keyPair.extractPrivateKeyBytes();
      final pubBytes = Uint8List.fromList(pubKey.bytes);

      // Encode as OpenSSH private key
      final opensshBytes = _encodeOpenSshPrivateKey(privBytes, pubBytes);
      const name = 'identity';
      await _settings.savePrivateKey(opensshBytes, name);

      setState(() {
        _privateKeyBytes = opensshBytes;
        _privateKeyPath = name;
        _myPublicKey = pubBytes;
        _error = null;
        _isGenerating = false;
      });
      _tryApplyConfig();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('New key generated and saved')),
        );
      }
    } catch (e) {
      setState(() {
        _error = 'Key generation failed: $e';
        _isGenerating = false;
      });
    }
  }

  /// Encode raw Ed25519 seed+public key as OpenSSH private key format.
  /// Produces the minimal PEM-like structure our parser accepts.
  Uint8List _encodeOpenSshPrivateKey(List<int> seed, Uint8List pubKey) {
    // Build the OpenSSH binary format manually
    // auth_magic + null byte
    const magic = 'openssh-key-v1\x00';
    // cipher "none", kdf "none", kdf options "", number of keys = 1
    final header = _sshString('none') + // cipher name
        _sshString('none') + // kdf name
        _sshString('') + // kdf options
        _uint32(1); // number of keys

    // Public key block: type + pub key
    final pubKeyBlock = _sshString('ssh-ed25519') + _sshString(pubKey);
    final pubKeyWrapped = _sshString(pubKeyBlock);

    // Private key block: checkint x2 + type + pubkey + full privkey (seed+pub) + comment
    final rng = Random.secure();
    final check = rng.nextInt(0xFFFFFFFF);
    final fullPriv = Uint8List(64)
      ..setAll(0, seed)
      ..setAll(32, pubKey);
    final privBlock = _uint32(check) +
        _uint32(check) +
        _sshString('ssh-ed25519') +
        _sshString(pubKey) +
        _sshString(fullPriv) +
        _sshString('sgtp-generated');
    // Pad to block size 8
    final padded = List<int>.from(privBlock);
    int pad = 1;
    while (padded.length % 8 != 0) padded.add(pad++);
    final privWrapped = _sshString(padded);

    final body = magic.codeUnits + header + pubKeyWrapped + privWrapped;
    final b64 = base64Encode(body);
    // Wrap at 70 chars
    final lines = StringBuffer('-----BEGIN OPENSSH PRIVATE KEY-----\n');
    for (var i = 0; i < b64.length; i += 70) {
      lines
          .writeln(b64.substring(i, i + 70 > b64.length ? b64.length : i + 70));
    }
    lines.write('-----END OPENSSH PRIVATE KEY-----');
    return Uint8List.fromList(lines.toString().codeUnits);
  }

  List<int> _sshString(dynamic data) {
    final bytes = data is String ? data.codeUnits : (data as List<int>);
    return _uint32(bytes.length) + bytes;
  }

  List<int> _uint32(int v) =>
      [(v >> 24) & 0xFF, (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF];

  // ── Whitelist: load folder ────────────────────────────────────────────────

  Future<void> _pickWhitelistFolder() async {
    try {
      final dirPath = await FilePicker.platform.getDirectoryPath();
      if (dirPath == null) return;
      final dir = Directory(dirPath);
      final entries = <WhitelistEntry>[];
      await for (final entity in dir.list(recursive: false)) {
        if (entity is File) {
          try {
            final bytes = await entity.readAsBytes();
            final pubKey = tryParsePublicKeyFile(bytes);
            if (pubKey != null) {
              var name = entity.path.split(Platform.pathSeparator).last;
              if (name.toLowerCase().endsWith('.pub')) {
                name = name.substring(0, name.length - 4);
              }
              entries.add(WhitelistEntry(bytes: pubKey, name: name));
            }
          } catch (_) {}
        }
      }
      if (entries.isEmpty) {
        _setError('No valid ed25519 keys found in folder');
        return;
      }
      await _settings.saveWhitelistEntries(entries);
      setState(() {
        _wlEntries = entries;
        _nicknames = _buildNicknames(entries);
        _error = null;
      });
      _tryApplyConfig();
    } catch (e) {
      _setError('Failed to load whitelist: $e');
    }
  }

  // ── Whitelist: load files ─────────────────────────────────────────────────

  Future<void> _pickWhitelistFiles() async {
    try {
      final result = await FilePicker.platform
          .pickFiles(type: FileType.any, withData: true, allowMultiple: true);
      if (result == null || result.files.isEmpty) return;
      final entries = <WhitelistEntry>[];
      for (final file in result.files) {
        final bytes = file.bytes;
        if (bytes == null) continue;
        final pubKey = tryParsePublicKeyFile(bytes);
        if (pubKey != null) {
          var name = file.name;
          if (name.toLowerCase().endsWith('.pub'))
            name = name.substring(0, name.length - 4);
          entries.add(WhitelistEntry(bytes: pubKey, name: name));
        }
      }
      if (entries.isEmpty) {
        _setError('No valid ed25519 keys found');
        return;
      }
      final combined = [..._wlEntries];
      for (final e in entries) {
        if (!combined.any((x) => x.hexKey == e.hexKey)) combined.add(e);
      }
      await _settings.saveWhitelistEntries(combined);
      setState(() {
        _wlEntries = combined;
        _nicknames = _buildNicknames(combined);
        _error = null;
      });
      _tryApplyConfig();
    } catch (e) {
      _setError('Failed to load whitelist files: $e');
    }
  }

  // ── Whitelist: paste from clipboard ──────────────────────────────────────

  Future<void> _pastePublicKeyFromClipboard() async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = data?.text?.trim() ?? '';
      if (text.isEmpty) {
        _setError('Clipboard is empty');
        return;
      }
      final bytes = Uint8List.fromList(text.codeUnits);
      final pubKey = tryParsePublicKeyFile(bytes);
      if (pubKey == null) {
        // Try hex decode
        final hexEntry = _tryHexKey(text);
        if (hexEntry == null) {
          _setError('Not a valid Ed25519 public key');
          return;
        }
        await _addWhitelistEntry(hexEntry);
      } else {
        final name = 'peer_${_wlEntries.length + 1}';
        await _addWhitelistEntry(WhitelistEntry(bytes: pubKey, name: name));
      }
    } catch (e) {
      _setError('Paste failed: $e');
    }
  }

  WhitelistEntry? _tryHexKey(String hex) {
    hex = hex.replaceAll(RegExp(r'\s'), '');
    if (hex.length != 64) return null;
    try {
      final bytes = Uint8List.fromList(List.generate(
          32, (i) => int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16)));
      return WhitelistEntry(
          bytes: bytes, name: 'peer_${_wlEntries.length + 1}');
    } catch (_) {
      return null;
    }
  }

  Future<void> _addWhitelistEntry(WhitelistEntry entry) async {
    if (_wlEntries.any((e) => e.hexKey == entry.hexKey)) {
      _setError('Key already in whitelist');
      return;
    }
    final combined = [..._wlEntries, entry];
    await _settings.saveWhitelistEntries(combined);
    setState(() {
      _wlEntries = combined;
      _nicknames = _buildNicknames(combined);
      _error = null;
    });
    _tryApplyConfig();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Added "${entry.name}" to whitelist')),
      );
    }
  }

  // ── Whitelist: rename ─────────────────────────────────────────────────────

  Future<void> _renameEntry(int index) async {
    final entry = _wlEntries[index];
    final ctrl = TextEditingController(text: entry.name);
    final newName = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Rename Peer'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Display name'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(context, ctrl.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (newName == null || newName.isEmpty) return;
    final updated = List<WhitelistEntry>.from(_wlEntries);
    updated[index] = entry.copyWithName(newName);
    await _settings.saveWhitelistEntries(updated);
    setState(() {
      _wlEntries = updated;
      _nicknames = _buildNicknames(updated);
    });
    _tryApplyConfig();
  }

  // ── Whitelist: remove ─────────────────────────────────────────────────────

  Future<void> _removeEntry(int index) async {
    final newList = List<WhitelistEntry>.from(_wlEntries)..removeAt(index);
    await _settings.saveWhitelistEntries(newList);
    setState(() {
      _wlEntries = newList;
      _nicknames = _buildNicknames(newList);
    });
    _tryApplyConfig();
  }

  // ── User avatar ───────────────────────────────────────────────────────────

  Future<void> _pickUserAvatar() async {
    final picker = ImagePicker();
    final file = await picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 512,
      maxHeight: 512,
      imageQuality: 80,
    );
    if (file == null) return;
    final bytes = await file.readAsBytes();
    await _settings.saveUserAvatar(bytes);
    setState(() {
      _userAvatar = bytes;
      _error = null;
    });
    widget.onUserAvatarChanged?.call(bytes);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Avatar saved')),
      );
    }
  }

  Future<void> _removeUserAvatar() async {
    await _settings.clearUserAvatar();
    setState(() => _userAvatar = null);
    widget.onUserAvatarChanged?.call(null);
  }

  // ── Config apply ──────────────────────────────────────────────────────────

  void _tryApplyConfig() {
    if (_privateKeyBytes == null || _myPublicKey == null) return;
    var server = _serverCtrl.text.trim();
    // Strip any scheme the mobile keyboard may have auto-inserted
    server = server
        .replaceAll(RegExp(r'^https?://', caseSensitive: false), '')
        .replaceAll(RegExp(r'^wss?://', caseSensitive: false), '')
        .trim();
    // Sync the controller text silently if it changed
    if (server != _serverCtrl.text) {
      _serverCtrl.value = _serverCtrl.value.copyWith(
        text: server,
        selection: TextSelection.collapsed(offset: server.length),
      );
    }
    try {
      final parsed = parseOpenSshPrivateKey(_privateKeyBytes!);
      final keyPair = makeKeyPair(parsed.seed, parsed.publicKey);
      final whitelist = _wlEntries.map((e) => e.hexKey).toSet();
      final newConfig = SgtpConfig(
        serverAddr: server.isEmpty ? 'localhost:7777' : server,
        roomUUID: Uint8List(16),
        identityKeyPair: keyPair,
        myPublicKey: parsed.publicKey,
        whitelist: whitelist,
        pingIntervalSeconds: _pingIntervalSeconds,
        mediaChunkSizeBytes: _mediaChunkSizeBytes,
      );
      widget.onConfigChanged?.call(newConfig, _nicknames, server);
    } catch (e) {
      _setError('Config error: $e');
    }
  }

  void _setError(String msg) => setState(() => _error = msg);

  // ── Nodes ────────────────────────────────────────────────────────────────

  Future<void> _reloadNodes() async {
    final nodes = await _settings.loadNodes();
    if (!mounted) return;
    setState(() {
      _nodes = nodes;
      _nodesLoading = false;
    });
  }

  Future<NodeConfig?> _openNodeEditor({NodeConfig? existing}) async {
    final base = existing ??
        NodeConfig(
          id: uuidBytesToHex(generateUUIDv7()),
          name: 'Node',
          host: 'localhost',
          chatPort: 7777,
          voicePort: 7777,
          usersPort: 7777,
        );

    final nameCtrl = TextEditingController(text: base.name);
    final hostCtrl = TextEditingController(text: base.host);
    final chatCtrl = TextEditingController(text: base.chatPort.toString());
    final voiceCtrl = TextEditingController(text: base.voicePort.toString());
    final usersCtrl = TextEditingController(text: base.usersPort.toString());

    NodeConfig? result;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.bgSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(
              20, 20, 20, MediaQuery.of(context).viewInsets.bottom + 20),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  existing == null ? 'Add Node' : 'Edit Node',
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: nameCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Name',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: hostCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Domain or IP',
                    border: OutlineInputBorder(),
                  ),
                  autocorrect: false,
                  enableSuggestions: false,
                  textCapitalization: TextCapitalization.none,
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: chatCtrl,
                        decoration: const InputDecoration(
                          labelText: 'Chat port',
                          border: OutlineInputBorder(),
                        ),
                        keyboardType: TextInputType.number,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: voiceCtrl,
                        decoration: const InputDecoration(
                          labelText: 'Voice port',
                          border: OutlineInputBorder(),
                        ),
                        keyboardType: TextInputType.number,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: usersCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Users port',
                    border: OutlineInputBorder(),
                  ),
                  keyboardType: TextInputType.number,
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: TextButton(
                        onPressed: () => Navigator.of(context).pop(),
                        child: const Text('Cancel'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton(
                        onPressed: () {
                          final name = nameCtrl.text.trim().isEmpty
                              ? 'Node'
                              : nameCtrl.text.trim();
                          final host = hostCtrl.text
                              .trim()
                              .replaceAll(
                                  RegExp(r'^https?://', caseSensitive: false),
                                  '')
                              .replaceAll(
                                  RegExp(r'^wss?://', caseSensitive: false), '')
                              .trim();
                          int? parsePort(String s) => int.tryParse(s.trim());

                          final chatPort = parsePort(chatCtrl.text);
                          final voicePort = parsePort(voiceCtrl.text);
                          final usersPort = parsePort(usersCtrl.text);

                          bool validPort(int? p) =>
                              p != null && p > 0 && p <= 65535;
                          if (host.isEmpty ||
                              !validPort(chatPort) ||
                              !validPort(voicePort) ||
                              !validPort(usersPort)) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text(
                                    'Please enter a host and valid ports (1–65535)'),
                              ),
                            );
                            return;
                          }

                          result = base.copyWith(
                            name: name,
                            host: host,
                            chatPort: chatPort!,
                            voicePort: voicePort!,
                            usersPort: usersPort!,
                          );
                          Navigator.of(context).pop();
                        },
                        child: const Text('Save'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );

    nameCtrl.dispose();
    hostCtrl.dispose();
    chatCtrl.dispose();
    voiceCtrl.dispose();
    usersCtrl.dispose();
    return result;
  }

  Future<void> _addNode() async {
    final node = await _openNodeEditor();
    if (node == null) return;
    await _settings.upsertNode(node);
    await _reloadNodes();
  }

  Future<void> _editNode(NodeConfig node) async {
    final updated = await _openNodeEditor(existing: node);
    if (updated == null) return;
    await _settings.upsertNode(updated);
    await _reloadNodes();
  }

  Future<void> _deleteNode(NodeConfig node) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete Node?'),
        content: Text('Delete "${node.name}" (${node.chatAddress})?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _settings.deleteNode(node.id);
    await _reloadNodes();
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bgMain,
      appBar: const _SettingsAppBar(),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 100),
        children: [
          _buildProfileSection(),
          _SettingsGroup(title: 'Nodes', child: _buildNodesCard()),
          _SettingsGroup(
              title: 'Private Key (Ed25519)', child: _buildPrivateKeyCard()),
          _SettingsGroup(title: 'Network', child: _buildNetworkCard()),
          _SettingsGroup(title: 'Media', child: _buildMediaCard()),
          _SettingsGroup(title: 'Interaction', child: _buildInteractionCard()),
          _buildGettingStarted(),
          _SettingsGroup(title: 'Logs', child: _buildLogsCard()),
          _SettingsGroup(title: 'About', child: _buildAboutCard()),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  // ── Profile section ───────────────────────────────────────────────────────

  Future<void> _saveNickname(String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('sgtp_user_nickname', value.trim());
    setState(() => _nickname = value.trim());
  }

  void _showMyProfileShare() {
    if (_myPublicKey == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No public key loaded yet')),
      );
      return;
    }
    final hexKey =
        _myPublicKey!.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    final shareData = QrShareData(
      type: 'profile',
      publicKeyHex: hexKey,
      nickname: _nickname.isEmpty ? null : _nickname,
      timestamp: DateTime.now().millisecondsSinceEpoch,
    );

    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.bgSurface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => SafeArea(
        child: PrettyQrSharePanel(
          data: shareData,
          title: _nickname.isEmpty ? 'My Profile' : _nickname,
          subtitle:
              '${hexKey.substring(0, 8)}…${hexKey.substring(hexKey.length - 8)}',
          description:
              'Share this so others can add you as a contact without typing your key manually.',
          copyMessage: 'Profile hex copied',
          exportName: _nickname.isEmpty
              ? 'my-profile'
              : 'profile-${_nickname.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-')}',
        ),
      ),
    );
  }

  Widget _buildProfileSection() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Avatar tap area
          GestureDetector(
            onTap: _pickUserAvatar,
            onLongPress: _userAvatar != null ? _removeUserAvatar : null,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Container(
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: AppColors.bgSurface,
                    border: Border.all(color: AppColors.border),
                    image: _userAvatar != null
                        ? DecorationImage(
                            image: MemoryImage(_userAvatar!), fit: BoxFit.cover)
                        : null,
                  ),
                  child: _userAvatar == null
                      ? const Icon(Icons.person,
                          size: 28, color: AppColors.textSecondary)
                      : null,
                ),
                Positioned(
                  bottom: -2,
                  right: -2,
                  child: Container(
                    width: 24,
                    height: 24,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: AppColors.bgSurfaceActive,
                      border: Border.all(color: AppColors.bgMain, width: 2),
                    ),
                    child: const Icon(Icons.photo_camera,
                        size: 13, color: AppColors.textPrimary),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 14),

          // Nickname field + share button
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Nickname text field
                Container(
                  height: 32,
                  decoration: BoxDecoration(
                    color: AppColors.bgSurface,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: AppColors.border),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: TextField(
                    controller: _nicknameCtrl,
                    minLines: 1,
                    maxLines: 1,
                    onChanged: _saveNickname,
                    onSubmitted: _saveNickname,
                    textAlignVertical: TextAlignVertical.center,
                    style: const TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        height: 1),
                    strutStyle: const StrutStyle(
                      fontSize: 14,
                      height: 1,
                      forceStrutHeight: true,
                    ),
                    decoration: const InputDecoration(
                      hintText: 'Your nickname…',
                      hintStyle: TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: 14,
                          height: 1),
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      filled: false,
                      isDense: true,
                      contentPadding: EdgeInsets.zero,
                      prefixIcon: Padding(
                        padding: EdgeInsets.only(top: 1),
                        child: Icon(Icons.badge_outlined,
                            size: 15, color: AppColors.textSecondary),
                      ),
                      prefixIconConstraints:
                          BoxConstraints(minWidth: 24, minHeight: 0),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                // Share profile button
                GestureDetector(
                  onTap: _showMyProfileShare,
                  child: Container(
                    height: 32,
                    decoration: BoxDecoration(
                      color: AppColors.bgSurface,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: AppColors.border),
                    ),
                    child: const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.ios_share_outlined,
                            size: 14, color: AppColors.textSecondary),
                        SizedBox(width: 5),
                        Text('Share My Profile',
                            style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w500,
                                color: AppColors.textSecondary)),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── Nodes card ───────────────────────────────────────────────────────────

  Widget _buildNodesCard() {
    if (_nodesLoading) {
      return const Row(
        children: [
          SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
          SizedBox(width: 12),
          Text('Loading…', style: TextStyle(fontSize: 14, color: AppColors.textSecondary)),
        ],
      );
    }

    if (_nodes.isEmpty) {
      return Row(
        children: [
          const Expanded(
            child: Text('No nodes yet',
                style: TextStyle(fontSize: 14, color: AppColors.textSecondary)),
          ),
          _ActionButton(
            icon: Icons.add_circle_outline,
            label: 'Add',
            onPressed: _addNode,
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: Alignment.centerRight,
          child: _ActionButton(
            icon: Icons.add_circle_outline,
            label: 'Add',
            onPressed: _addNode,
          ),
        ),
        const SizedBox(height: 14),
        ..._nodes.map((n) => _NodeRow(
              node: n,
              onEdit: () => _editNode(n),
              onDelete: () => _deleteNode(n),
            )),
      ],
    );
  }

  // ── Private key card ──────────────────────────────────────────────────────

  Widget _buildPrivateKeyCard() {
    final pubHex =
        _myPublicKey?.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          _privateKeyPath ?? 'No key loaded',
          style: const TextStyle(
            fontFamily: 'monospace',
            fontSize: 13,
            color: AppColors.textSecondary,
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _ActionButton(
              icon: Icons.folder_open_outlined,
              label: 'Browse',
              onPressed: _isLoading ? null : _pickPrivateKey,
            ),
            _ActionButton(
              icon: Icons.key_outlined,
              label: 'Generate',
              loading: _isGenerating,
              onPressed:
                  (_isLoading || _isGenerating) ? null : _generatePrivateKey,
            ),
          ],
        ),
        if (pubHex != null) ...[
          const SizedBox(height: 16),
          const Text(
            'Public Key',
            style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
          ),
          const SizedBox(height: 8),
          Container(
            height: 44,
            decoration: BoxDecoration(
              color: AppColors.bgMain,
              border: Border.all(color: AppColors.border),
              borderRadius: BorderRadius.circular(8),
            ),
            padding: const EdgeInsets.fromLTRB(12, 0, 6, 0),
            child: Row(
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: SelectableText(
                        pubHex,
                        maxLines: 1,
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 12,
                          color: AppColors.textPrimary,
                          height: 1.1,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: () {
                    Clipboard.setData(ClipboardData(text: pubHex));
                    ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Public key copied')));
                  },
                  child: Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: AppColors.bgSurfaceActive,
                      border: Border.all(color: AppColors.border),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Icon(Icons.content_copy,
                        size: 16, color: AppColors.textPrimary),
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  // ── Whitelist card ────────────────────────────────────────────────────────

  Widget _buildWhitelistCard() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Only listed keys can connect.',
          style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _ActionButton(
              icon: Icons.snippet_folder_outlined,
              label: 'Folder',
              onPressed: _pickWhitelistFolder,
            ),
            _ActionButton(
              icon: Icons.description_outlined,
              label: 'Files',
              onPressed: _pickWhitelistFiles,
            ),
            _ActionButton(
              icon: Icons.content_paste_outlined,
              label: 'Paste',
              onPressed: _pastePublicKeyFromClipboard,
            ),
          ],
        ),
        if (_wlEntries.isNotEmpty) ...[
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: List.generate(_wlEntries.length, (i) {
              final entry = _wlEntries[i];
              return Container(
                decoration: BoxDecoration(
                  color: AppColors.bgMain,
                  border: Border.all(color: AppColors.border),
                  borderRadius: BorderRadius.circular(16),
                ),
                padding: const EdgeInsets.only(
                    left: 12, right: 10, top: 6, bottom: 6),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    GestureDetector(
                      onTap: () => _renameEntry(i),
                      child: Text(
                        entry.name,
                        style: const TextStyle(
                          fontSize: 14,
                          color: AppColors.textPrimary,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    GestureDetector(
                      onTap: () => _showDeleteConfirm(i),
                      child: const Icon(Icons.close,
                          size: 16, color: AppColors.statusRed),
                    ),
                  ],
                ),
              );
            }),
          ),
        ],
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(_error!,
              style: const TextStyle(fontSize: 13, color: AppColors.statusRed)),
        ],
      ],
    );
  }

  // ── Network card ──────────────────────────────────────────────────────────

  Widget _buildNetworkCard() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Ping interval',
          style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 4,
                  thumbShape:
                      const RoundSliderThumbShape(enabledThumbRadius: 10),
                  overlayShape:
                      const RoundSliderOverlayShape(overlayRadius: 18),
                  activeTrackColor: AppColors.border,
                  inactiveTrackColor: AppColors.border,
                  thumbColor: Colors.white,
                  overlayColor: Colors.white.withAlpha(30),
                ),
                child: Slider(
                  value: _pingIntervalSeconds.toDouble(),
                  min: 5,
                  max: 120,
                  onChanged: (v) {
                    setState(() => _pingIntervalSeconds = v.round());
                    SharedPreferences.getInstance().then(
                      (p) =>
                          p.setInt('sgtp_ping_interval', _pingIntervalSeconds),
                    );
                    _tryApplyConfig();
                  },
                ),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 40,
              child: Text(
                '${_pingIntervalSeconds} s',
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 13,
                  color: AppColors.textSecondary,
                ),
                textAlign: TextAlign.right,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildMediaCard() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SwitchRow(
          label: 'Compress my files',
          value: _compressFiles,
          onChanged: (v) async {
            final updated = MediaTransferSettings(
              compressFiles: v,
              compressPhotos: _compressPhotos,
              compressVideos: _compressVideos,
              mediaChunkSizeBytes: _mediaChunkSizeBytes,
            );
            await _settings.saveMediaTransferSettings(updated);
            setState(() => _compressFiles = v);
          },
        ),
        if (_compressFiles) ...[
          const SizedBox(height: 8),
          const Text(
            'Compress selected file types before upload.',
            style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              _ChoiceChip(
                label: 'Photos',
                selected: _compressPhotos,
                onTap: () async {
                  final next = !_compressPhotos;
                  final updated = MediaTransferSettings(
                    compressFiles: _compressFiles,
                    compressPhotos: next,
                    compressVideos: _compressVideos,
                    mediaChunkSizeBytes: _mediaChunkSizeBytes,
                  );
                  await _settings.saveMediaTransferSettings(updated);
                  setState(() => _compressPhotos = next);
                },
              ),
              const SizedBox(width: 8),
              _ChoiceChip(
                label: 'Videos',
                selected: _compressVideos,
                onTap: () async {
                  final next = !_compressVideos;
                  final updated = MediaTransferSettings(
                    compressFiles: _compressFiles,
                    compressPhotos: _compressPhotos,
                    compressVideos: next,
                    mediaChunkSizeBytes: _mediaChunkSizeBytes,
                  );
                  await _settings.saveMediaTransferSettings(updated);
                  setState(() => _compressVideos = next);
                },
              ),
            ],
          ),
        ],
        const SizedBox(height: 16),
        const Text(
          'Outgoing media chunk size',
          style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: SgtpConstants.allowedMediaChunkSizes.map((size) {
            final selected = _mediaChunkSizeBytes == size;
            final kb = size ~/ 1024;
            return _ChoiceChip(
              label: '$kb KB',
              selected: selected,
              onTap: () async {
                final updated = MediaTransferSettings(
                  compressFiles: _compressFiles,
                  compressPhotos: _compressPhotos,
                  compressVideos: _compressVideos,
                  mediaChunkSizeBytes: size,
                );
                await _settings.saveMediaTransferSettings(updated);
                setState(() => _mediaChunkSizeBytes = size);
                _tryApplyConfig();
              },
            );
          }).toList(),
        ),
      ],
    );
  }

  // ── Interaction card ──────────────────────────────────────────────────────

  Widget _buildInteractionCard() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── Swipe to reply (mobile) ─────────────────────────────────────
        _SwitchRow(
          label: 'Swipe right to reply (mobile)',
          value: _swipeToReply,
          onChanged: (v) {
            setState(() => _swipeToReply = v);
            InteractionPrefs.setSwipeToReply(v);
          },
        ),
        const SizedBox(height: 8),
        // ── Long-press shows full menu ──────────────────────────────────
        _SwitchRow(
          label: 'Long-press shows menu (react + reply)',
          value: _longPressMenu,
          onChanged: (v) {
            setState(() => _longPressMenu = v);
            InteractionPrefs.setLongPressShowsMenu(v);
          },
        ),
        const SizedBox(height: 12),
        // ── Desktop double-click action ─────────────────────────────────
        const Text(
          'Desktop double-click',
          style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            _ChoiceChip(
              label: 'Open react picker',
              selected: _doubleTapDesktop == 'react',
              onTap: () {
                setState(() => _doubleTapDesktop = 'react');
                InteractionPrefs.setDoubleTapDesktop('react');
              },
            ),
            const SizedBox(width: 8),
            _ChoiceChip(
              label: 'Set reply',
              selected: _doubleTapDesktop == 'reply',
              onTap: () {
                setState(() => _doubleTapDesktop = 'reply');
                InteractionPrefs.setDoubleTapDesktop('reply');
              },
            ),
          ],
        ),
      ],
    );
  }

  // ── Getting Started (collapsible) ─────────────────────────────────────────

  Widget _buildGettingStarted() {
    const steps = [
      ('Generate key:', 'Create or load an Ed25519 private key.'),
      ('Add peers:', 'Whitelist public keys of your friends.'),
      ('Server:', 'Enter a valid SGTP relay address.'),
      ('Rooms:', 'Create a new room or join by UUID.'),
      ('Chat:', 'Send messages (End-to-End Encrypted).'),
    ];
    return Container(
      margin: const EdgeInsets.only(bottom: 24),
      decoration: const BoxDecoration(
        color: AppColors.bgSurface,
        border: Border(
          top: BorderSide(color: AppColors.border),
          bottom: BorderSide(color: AppColors.border),
        ),
      ),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 20),
          childrenPadding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          title: const Text(
            'Getting Started',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w500,
              color: AppColors.textPrimary,
            ),
          ),
          iconColor: AppColors.textSecondary,
          collapsedIconColor: AppColors.textSecondary,
          children: [
            const Text(
              'Follow these steps to start chatting securely:',
              style: TextStyle(
                  fontSize: 14, color: AppColors.textSecondary, height: 1.6),
            ),
            const SizedBox(height: 8),
            ...List.generate(steps.length, (i) {
              final step = steps[i];
              return Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${i + 1}. ',
                        style: const TextStyle(
                            fontSize: 14, color: AppColors.textSecondary)),
                    Expanded(
                      child: Text.rich(TextSpan(children: [
                        TextSpan(
                          text: '${step.$1} ',
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: AppColors.textPrimary,
                          ),
                        ),
                        TextSpan(
                          text: step.$2,
                          style: const TextStyle(
                            fontSize: 14,
                            color: AppColors.textSecondary,
                            height: 1.6,
                          ),
                        ),
                      ])),
                    ),
                  ],
                ),
              );
            }),
          ],
        ),
      ),
    );
  }

  // ── Logs card ─────────────────────────────────────────────────────────────

  Widget _buildLogsCard() {
    return ListenableBuilder(
      listenable: _LogsCountNotifier(),
      builder: (_, __) {
        final count = AppLogger.entries.length;
        return Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    count == 0
                        ? 'No log entries yet'
                        : '$count entries in memory',
                    style: const TextStyle(
                        fontSize: 14, color: AppColors.textSecondary),
                  ),
                  const SizedBox(height: 2),
                  const Text(
                    'Tap to view live logs, filter by level, or copy.',
                    style:
                        TextStyle(fontSize: 12, color: AppColors.textSecondary),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            _ActionButton(
              icon: Icons.article_outlined,
              label: 'View',
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const LogsScreen(),
                  ),
                );
              },
            ),
          ],
        );
      },
    );
  }

  // ── About card ────────────────────────────────────────────────────────────

  Widget _buildAboutCard() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _AboutRow(label: 'App Version', value: '1.0.0-beta'),
        const SizedBox(height: 4),
        _AboutRow(label: 'Protocol', value: 'SGTP v1'),
        const SizedBox(height: 12),
        GestureDetector(
          onTap: _launchGitHub,
          child: const Row(
            children: [
              Icon(Icons.open_in_new, size: 18, color: Color(0xFF0A84FF)),
              SizedBox(width: 4),
              Text(
                'GitHub Repository',
                style: TextStyle(fontSize: 14, color: Color(0xFF0A84FF)),
              ),
            ],
          ),
        ),
      ],
    );
  }

  void _showDeleteConfirm(int index) {
    final entry = _wlEntries[index];
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Remove Peer'),
        content: Text(
            'Remove "${entry.name}" from whitelist?\n\nThis applies to new rooms immediately.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _removeEntry(index);
            },
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
  }

  Future<void> _launchGitHub() async {
    final uri = Uri.parse('https://github.com/SecureGroupTP/sgtp_flutter');
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not open browser')),
        );
      }
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Shared UI components
// ─────────────────────────────────────────────────────────────────────────────

class _SettingsAppBar extends StatelessWidget implements PreferredSizeWidget {
  const _SettingsAppBar();

  @override
  Size get preferredSize => const Size.fromHeight(64);

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.bgMain,
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: SafeArea(
        bottom: false,
        child: SizedBox(
          height: preferredSize.height,
          child: const Padding(
            padding: EdgeInsets.symmetric(horizontal: 20),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Settings',
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w600,
                  letterSpacing: -0.5,
                  color: AppColors.textPrimary,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Section header label + full-bleed settings card (bgSurface, top/bottom borders).
class _SettingsGroup extends StatelessWidget {
  final String title;
  final Widget child;
  const _SettingsGroup({required this.title, required this.child});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
          child: Text(
            title.toUpperCase(),
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: AppColors.textSecondary,
              letterSpacing: 1,
            ),
          ),
        ),
        Container(
          margin: const EdgeInsets.only(bottom: 24),
          decoration: const BoxDecoration(
            color: AppColors.bgSurface,
            border: Border(
              top: BorderSide(color: AppColors.border),
              bottom: BorderSide(color: AppColors.border),
            ),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          child: child,
        ),
      ],
    );
  }
}

/// Small tinted button used in settings cards (Browse, Generate, Folder…).
class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool loading;
  final VoidCallback? onPressed;

  const _ActionButton({
    required this.icon,
    required this.label,
    this.loading = false,
    this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null && !loading;
    return GestureDetector(
      onTap: enabled ? onPressed : null,
      child: Opacity(
        opacity: enabled ? 1.0 : 0.4,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: AppColors.bgSurfaceActive,
            border: Border.all(color: AppColors.border),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (loading)
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: AppColors.textPrimary),
                )
              else
                Icon(icon, size: 18, color: AppColors.textPrimary),
              const SizedBox(width: 6),
              Text(
                label,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: AppColors.textPrimary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NodeRow extends StatelessWidget {
  final NodeConfig node;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _NodeRow({
    required this.node,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.bgSurfaceActive,
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        node.name,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: AppColors.textPrimary,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  node.chatAddress,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                    color: AppColors.textSecondary,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'chat:${node.chatPort}  voice:${node.voicePort}  users:${node.usersPort}',
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          IconButton(
            tooltip: 'Edit',
            onPressed: onEdit,
            icon: const Icon(Icons.edit_outlined,
                size: 20, color: AppColors.textSecondary),
          ),
          IconButton(
            tooltip: 'Delete',
            onPressed: onDelete,
            icon: const Icon(Icons.delete_outline,
                size: 20, color: AppColors.statusRed),
          ),
        ],
      ),
    );
  }
}

class _AboutRow extends StatelessWidget {
  final String label;
  final String value;
  const _AboutRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label,
            style:
                const TextStyle(fontSize: 14, color: AppColors.textSecondary)),
        Text(value,
            style: const TextStyle(fontSize: 14, color: AppColors.textPrimary)),
      ],
    );
  }
}

// Thin ChangeNotifier that fires whenever AppLogger gains or loses entries,
// so the Settings "Logs" card reflects the current count in real time.
class _LogsCountNotifier extends ChangeNotifier {
  _LogsCountNotifier() {
    AppLogger.addListener(_update);
  }

  void _update(LogEntry _) => notifyListeners();

  @override
  void dispose() {
    AppLogger.removeListener(_update);
    super.dispose();
  }
}

// ─── Interaction settings helpers ─────────────────────────────────────────────

class _SwitchRow extends StatelessWidget {
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;
  const _SwitchRow(
      {required this.label, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(label,
              style:
                  const TextStyle(fontSize: 14, color: AppColors.textPrimary)),
        ),
        Switch(
          value: value,
          onChanged: onChanged,
          activeColor: AppColors.accentBlue,
          trackColor: WidgetStatePropertyAll(AppColors.border),
        ),
      ],
    );
  }
}

class _ChoiceChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _ChoiceChip(
      {required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected
              ? AppColors.accentBlue.withAlpha(40)
              : AppColors.bgSurfaceActive,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: selected ? AppColors.accentBlue : AppColors.border,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            color: selected ? AppColors.accentBlue : AppColors.textSecondary,
            fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
          ),
        ),
      ),
    );
  }
}
