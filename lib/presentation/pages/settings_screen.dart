import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/crypto/ed25519_utils.dart';
import '../../core/openssh_parser.dart';
import '../../data/repositories/settings_repository.dart';
import '../../data/sgtp_client.dart';
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
  final _settings   = SettingsRepository();
  final _serverCtrl = TextEditingController();

  String?    _privateKeyPath;
  Uint8List? _privateKeyBytes;
  Uint8List? _myPublicKey;

  List<WhitelistEntry> _wlEntries = [];
  Map<String, String>  _nicknames = {};

  Uint8List? _userAvatar;

  bool    _isLoading  = false;
  bool    _isGenerating = false;
  String? _error;

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
      _myPublicKey     = cfg.myPublicKey;
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
          _privateKeyPath  = savedKey.name;
          _myPublicKey     = parsed.publicKey;
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

    final avatar = await _settings.loadUserAvatar();
    if (avatar != null) setState(() => _userAvatar = avatar);
  }

  @override
  void dispose() {
    _serverCtrl.dispose();
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
      final file  = result.files.first;
      final bytes = file.bytes;
      if (bytes == null) { _setError('Could not read key file'); return; }
      final parsed = parseOpenSshPrivateKey(bytes);
      await _settings.savePrivateKey(bytes, file.name);
      setState(() {
        _privateKeyBytes = bytes;
        _privateKeyPath  = file.name;
        _myPublicKey     = parsed.publicKey;
        _error           = null;
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
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
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
      final keyPair   = await algorithm.newKeyPair();
      final pubKey    = await keyPair.extractPublicKey();
      final privBytes = await keyPair.extractPrivateKeyBytes();
      final pubBytes  = Uint8List.fromList(pubKey.bytes);

      // Encode as OpenSSH private key
      final opensshBytes = _encodeOpenSshPrivateKey(privBytes, pubBytes);
      const name         = 'identity';
      await _settings.savePrivateKey(opensshBytes, name);

      setState(() {
        _privateKeyBytes = opensshBytes;
        _privateKeyPath  = name;
        _myPublicKey     = pubBytes;
        _error           = null;
        _isGenerating    = false;
      });
      _tryApplyConfig();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('New key generated and saved')),
        );
      }
    } catch (e) {
      setState(() { _error = 'Key generation failed: $e'; _isGenerating = false; });
    }
  }

  /// Encode raw Ed25519 seed+public key as OpenSSH private key format.
  /// Produces the minimal PEM-like structure our parser accepts.
  Uint8List _encodeOpenSshPrivateKey(List<int> seed, Uint8List pubKey) {
    // Build the OpenSSH binary format manually
    // auth_magic + null byte
    const magic = 'openssh-key-v1\x00';
    // cipher "none", kdf "none", kdf options "", number of keys = 1
    final header = _sshString('none') +  // cipher name
        _sshString('none') +              // kdf name
        _sshString('') +                  // kdf options
        _uint32(1);                        // number of keys

    // Public key block: type + pub key
    final pubKeyBlock = _sshString('ssh-ed25519') + _sshString(pubKey);
    final pubKeyWrapped = _sshString(pubKeyBlock);

    // Private key block: checkint x2 + type + pubkey + full privkey (seed+pub) + comment
    final rng   = Random.secure();
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
    final b64  = base64Encode(body);
    // Wrap at 70 chars
    final lines = StringBuffer('-----BEGIN OPENSSH PRIVATE KEY-----\n');
    for (var i = 0; i < b64.length; i += 70) {
      lines.writeln(b64.substring(i, i + 70 > b64.length ? b64.length : i + 70));
    }
    lines.write('-----END OPENSSH PRIVATE KEY-----');
    return Uint8List.fromList(lines.toString().codeUnits);
  }

  List<int> _sshString(dynamic data) {
    final bytes = data is String ? data.codeUnits : (data as List<int>);
    return _uint32(bytes.length) + bytes;
  }

  List<int> _uint32(int v) => [
        (v >> 24) & 0xFF, (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF
      ];

  // ── Whitelist: load folder ────────────────────────────────────────────────

  Future<void> _pickWhitelistFolder() async {
    try {
      final dirPath = await FilePicker.platform.getDirectoryPath();
      if (dirPath == null) return;
      final dir     = Directory(dirPath);
      final entries = <WhitelistEntry>[];
      await for (final entity in dir.list(recursive: false)) {
        if (entity is File) {
          try {
            final bytes  = await entity.readAsBytes();
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
      if (entries.isEmpty) { _setError('No valid ed25519 keys found in folder'); return; }
      await _settings.saveWhitelistEntries(entries);
      setState(() { _wlEntries = entries; _nicknames = _buildNicknames(entries); _error = null; });
      _tryApplyConfig();
    } catch (e) { _setError('Failed to load whitelist: $e'); }
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
          if (name.toLowerCase().endsWith('.pub')) name = name.substring(0, name.length - 4);
          entries.add(WhitelistEntry(bytes: pubKey, name: name));
        }
      }
      if (entries.isEmpty) { _setError('No valid ed25519 keys found'); return; }
      final combined = [..._wlEntries];
      for (final e in entries) {
        if (!combined.any((x) => x.hexKey == e.hexKey)) combined.add(e);
      }
      await _settings.saveWhitelistEntries(combined);
      setState(() { _wlEntries = combined; _nicknames = _buildNicknames(combined); _error = null; });
      _tryApplyConfig();
    } catch (e) { _setError('Failed to load whitelist files: $e'); }
  }

  // ── Whitelist: paste from clipboard ──────────────────────────────────────

  Future<void> _pastePublicKeyFromClipboard() async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = data?.text?.trim() ?? '';
      if (text.isEmpty) { _setError('Clipboard is empty'); return; }
      final bytes    = Uint8List.fromList(text.codeUnits);
      final pubKey   = tryParsePublicKeyFile(bytes);
      if (pubKey == null) {
        // Try hex decode
        final hexEntry = _tryHexKey(text);
        if (hexEntry == null) { _setError('Not a valid Ed25519 public key'); return; }
        await _addWhitelistEntry(hexEntry);
      } else {
        final name = 'peer_${_wlEntries.length + 1}';
        await _addWhitelistEntry(WhitelistEntry(bytes: pubKey, name: name));
      }
    } catch (e) { _setError('Paste failed: $e'); }
  }

  WhitelistEntry? _tryHexKey(String hex) {
    hex = hex.replaceAll(RegExp(r'\s'), '');
    if (hex.length != 64) return null;
    try {
      final bytes = Uint8List.fromList(
          List.generate(32, (i) => int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16)));
      return WhitelistEntry(bytes: bytes, name: 'peer_${_wlEntries.length + 1}');
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
    setState(() { _wlEntries = combined; _nicknames = _buildNicknames(combined); _error = null; });
    _tryApplyConfig();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Added "${entry.name}" to whitelist')),
      );
    }
  }

  // ── Whitelist: rename ─────────────────────────────────────────────────────

  Future<void> _renameEntry(int index) async {
    final entry   = _wlEntries[index];
    final ctrl    = TextEditingController(text: entry.name);
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
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
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
    setState(() { _wlEntries = updated; _nicknames = _buildNicknames(updated); });
    _tryApplyConfig();
  }

  // ── Whitelist: remove ─────────────────────────────────────────────────────

  Future<void> _removeEntry(int index) async {
    final newList = List<WhitelistEntry>.from(_wlEntries)..removeAt(index);
    await _settings.saveWhitelistEntries(newList);
    setState(() { _wlEntries = newList; _nicknames = _buildNicknames(newList); });
    _tryApplyConfig();
  }

  // ── User avatar ───────────────────────────────────────────────────────────

  Future<void> _pickUserAvatar() async {
    final picker = ImagePicker();
    final file   = await picker.pickImage(
      source: ImageSource.gallery, maxWidth: 512, maxHeight: 512, imageQuality: 80,
    );
    if (file == null) return;
    final bytes = await file.readAsBytes();
    await _settings.saveUserAvatar(bytes);
    setState(() { _userAvatar = bytes; _error = null; });
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
    final server = _serverCtrl.text.trim();
    try {
      final parsed   = parseOpenSshPrivateKey(_privateKeyBytes!);
      final keyPair  = makeKeyPair(parsed.seed, parsed.publicKey);
      final whitelist = _wlEntries.map((e) => e.hexKey).toSet();
      final newConfig = SgtpConfig(
        serverAddr:      server.isEmpty ? 'localhost:7777' : server,
        roomUUID:        Uint8List(16),
        identityKeyPair: keyPair,
        myPublicKey:     parsed.publicKey,
        whitelist:       whitelist,
      );
      widget.onConfigChanged?.call(newConfig, _nicknames, server);
    } catch (e) { _setError('Config error: $e'); }
  }

  void _setError(String msg) => setState(() => _error = msg);

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Settings'), elevation: 0),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [

          // ── User Profile ───────────────────────────────────────────────
          _sectionTitle('My Profile'),
          const SizedBox(height: 8),
          _buildAvatarCard(theme),
          const SizedBox(height: 16),

          // ── Connection ──────────────────────────────────────────────────
          _sectionTitle('Connection'),
          const SizedBox(height: 8),
          TextField(
            controller: _serverCtrl,
            decoration: const InputDecoration(
              labelText: 'Server address',
              hintText: 'host:7777',
              prefixIcon: Icon(Icons.dns_outlined),
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => _tryApplyConfig(),
            onSubmitted: (_) => _tryApplyConfig(),
          ),
          const SizedBox(height: 16),

          // ── Private key ─────────────────────────────────────────────────
          _sectionTitle('Private Key (ed25519)'),
          const SizedBox(height: 8),
          _buildPrivateKeyCard(theme),
          const SizedBox(height: 16),

          // ── Whitelist ────────────────────────────────────────────────────
          _sectionTitle('Trusted Peers (Whitelist)'),
          const SizedBox(height: 4),
          Text(
            'Only listed keys can connect. Tap a peer to rename.',
            style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 8),
          _buildWhitelistButtons(theme),
          const SizedBox(height: 12),
          _buildWhitelistItems(theme),

          // ── Error ─────────────────────────────────────────────────────────
          if (_error != null) ...[
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: theme.colorScheme.errorContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(_error!,
                  style: TextStyle(color: theme.colorScheme.onErrorContainer)),
            ),
          ],

          const SizedBox(height: 32),
          const Divider(),
          const SizedBox(height: 8),

          // ── About ─────────────────────────────────────────────────────────
          _sectionTitle('About'),
          const SizedBox(height: 8),
          _infoRow('App Version', '1.0.0'),
          _infoRow('Protocol', 'SGTP v1'),
          const SizedBox(height: 12),

          // ── GitHub link ───────────────────────────────────────────────────
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.code_outlined),
            title: const Text('Source Code'),
            subtitle: const Text('github.com/SecureGroupTP/sgtp_flutter'),
            trailing: const Icon(Icons.open_in_new, size: 16),
            onTap: () => _launchGitHub(),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  // ── Avatar card ───────────────────────────────────────────────────────────

  Widget _buildAvatarCard(ThemeData theme) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: theme.colorScheme.outline),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            GestureDetector(
              onTap: _pickUserAvatar,
              child: Stack(
                children: [
                  CircleAvatar(
                    radius: 36,
                    backgroundImage:
                        _userAvatar != null ? MemoryImage(_userAvatar!) : null,
                    child: _userAvatar == null
                        ? const Icon(Icons.person, size: 32)
                        : null,
                  ),
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: Container(
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primary,
                        shape: BoxShape.circle,
                      ),
                      padding: const EdgeInsets.all(4),
                      child: Icon(Icons.camera_alt,
                          size: 14, color: theme.colorScheme.onPrimary),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Your Avatar',
                      style: theme.textTheme.titleSmall
                          ?.copyWith(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  Text(
                    'Shown next to your messages.\nOther peers see it too.',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                  if (_userAvatar != null) ...[
                    const SizedBox(height: 8),
                    TextButton.icon(
                      onPressed: _removeUserAvatar,
                      icon: const Icon(Icons.delete_outline, size: 16),
                      label: const Text('Remove'),
                      style: TextButton.styleFrom(
                          foregroundColor: theme.colorScheme.error,
                          padding: EdgeInsets.zero,
                          minimumSize: const Size(0, 32)),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Private key card ──────────────────────────────────────────────────────

  Widget _buildPrivateKeyCard(ThemeData theme) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: theme.colorScheme.outline),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Expanded(
                child: Text(
                  _privateKeyPath ?? 'No key loaded',
                  style: theme.textTheme.bodyMedium?.copyWith(
                      color: _privateKeyPath != null
                          ? theme.colorScheme.onSurface
                          : theme.colorScheme.onSurfaceVariant),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ]),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(
                child: FilledButton.tonalIcon(
                  onPressed: _isLoading ? null : _pickPrivateKey,
                  icon: const Icon(Icons.file_open_outlined, size: 18),
                  label: const Text('Browse'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton.tonalIcon(
                  onPressed: (_isLoading || _isGenerating) ? null : _generatePrivateKey,
                  icon: _isGenerating
                      ? const SizedBox(
                          width: 16, height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.auto_fix_high_outlined, size: 18),
                  label: const Text('Generate'),
                ),
              ),
            ]),
            if (_myPublicKey != null) ...[
              const SizedBox(height: 8),
              const Divider(),
              const SizedBox(height: 4),
              Text('Your public key (share with peers):',
                  style: theme.textTheme.labelSmall
                      ?.copyWith(color: theme.colorScheme.primary)),
              const SizedBox(height: 4),
              Row(children: [
                Expanded(
                  child: SelectableText(
                    _myPublicKey!
                        .map((b) => b.toRadixString(16).padLeft(2, '0'))
                        .join(),
                    style: theme.textTheme.bodySmall
                        ?.copyWith(fontFamily: 'monospace'),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.copy, size: 16),
                  tooltip: 'Copy public key',
                  onPressed: () {
                    final hex = _myPublicKey!
                        .map((b) => b.toRadixString(16).padLeft(2, '0'))
                        .join();
                    Clipboard.setData(ClipboardData(text: hex));
                    ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Public key copied')));
                  },
                ),
              ]),
            ],
          ],
        ),
      ),
    );
  }

  // ── Whitelist buttons ─────────────────────────────────────────────────────

  Widget _buildWhitelistButtons(ThemeData theme) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        FilledButton.tonalIcon(
          onPressed: _pickWhitelistFolder,
          icon: const Icon(Icons.folder_open_outlined, size: 18),
          label: const Text('Load Folder'),
        ),
        FilledButton.tonalIcon(
          onPressed: _pickWhitelistFiles,
          icon: const Icon(Icons.file_present_outlined, size: 18),
          label: const Text('Load Files'),
        ),
        FilledButton.tonalIcon(
          onPressed: _pastePublicKeyFromClipboard,
          icon: const Icon(Icons.content_paste_outlined, size: 18),
          label: const Text('Paste Key'),
        ),
      ],
    );
  }

  // ── Whitelist items ───────────────────────────────────────────────────────

  Widget _buildWhitelistItems(ThemeData theme) {
    if (_wlEntries.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          border: Border.all(color: theme.colorScheme.outlineVariant),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Center(
          child: Column(children: [
            Icon(Icons.person_off_outlined,
                size: 40, color: theme.colorScheme.outlineVariant),
            const SizedBox(height: 8),
            const Text('No peers in whitelist'),
            const SizedBox(height: 4),
            Text('Use "Load Files" or "Paste Key" to add trusted peers.',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                textAlign: TextAlign.center),
          ]),
        ),
      );
    }

    return Column(
      children: List.generate(_wlEntries.length, (i) {
        final entry = _wlEntries[i];
        return Card(
          margin: const EdgeInsets.only(bottom: 8),
          child: ListTile(
            leading: CircleAvatar(
              child: Text(entry.name.substring(0, 1).toUpperCase()),
            ),
            title: Text(entry.name,
                style: const TextStyle(fontWeight: FontWeight.w500)),
            subtitle: SelectableText(
              '${entry.hexKey.substring(0, 16)}…',
              style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
            ),
            onTap: () => _renameEntry(i),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: const Icon(Icons.copy, size: 18),
                  tooltip: 'Copy full key',
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: entry.hexKey));
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('${entry.name} key copied')));
                  },
                ),
                IconButton(
                  icon: const Icon(Icons.edit_outlined, size: 18),
                  tooltip: 'Rename',
                  onPressed: () => _renameEntry(i),
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline, color: Colors.red, size: 18),
                  tooltip: 'Remove',
                  onPressed: () => _showDeleteConfirm(i),
                ),
              ],
            ),
          ),
        );
      }),
    );
  }

  Widget _sectionTitle(String title) => Text(title,
      style: Theme.of(context)
          .textTheme
          .titleMedium
          ?.copyWith(fontWeight: FontWeight.bold));

  Widget _infoRow(String label, String value) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: const TextStyle(color: Colors.grey)),
        Text(value, style: const TextStyle(fontWeight: FontWeight.w500)),
      ],
    ),
  );

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
              onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          TextButton(
            onPressed: () { Navigator.pop(context); _removeEntry(index); },
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