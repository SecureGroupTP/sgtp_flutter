import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/crypto/ed25519_utils.dart';
import '../../core/openssh_parser.dart';
import '../../data/repositories/settings_repository.dart';
import '../../data/sgtp_client.dart';

typedef ConfigChangedCallback = void Function(
    SgtpConfig config, Map<String, String> nicknames, String serverAddress);

class SettingsScreen extends StatefulWidget {
  final SgtpConfig? initialConfig;
  final Map<String, String>? initialNicknames;
  final ConfigChangedCallback? onConfigChanged;

  const SettingsScreen({
    super.key,
    this.initialConfig,
    this.initialNicknames,
    this.onConfigChanged,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _settings         = SettingsRepository();
  final _serverCtrl       = TextEditingController();

  String?    _privateKeyPath;
  Uint8List? _privateKeyBytes;
  Uint8List? _myPublicKey;

  List<Uint8List> _wlBytes = [];
  List<String>    _wlPaths = [];
  Map<String, String> _nicknames = {};

  bool _isLoading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadFromConfig();
  }

  void _loadFromConfig() {
    final cfg = widget.initialConfig;
    if (cfg != null) {
      _serverCtrl.text = cfg.serverAddr;
      _myPublicKey     = cfg.myPublicKey;
    }
    _nicknames = Map.from(widget.initialNicknames ?? {});
    // Load full saved state from disk
    _loadFromDisk();
  }

  Future<void> _loadFromDisk() async {
    final savedKey = await _settings.loadPrivateKey();
    if (savedKey != null) {
      try {
        final parsed = parseOpenSshPrivateKey(savedKey.bytes);
        setState(() {
          _privateKeyBytes = savedKey.bytes;
          _privateKeyPath  = savedKey.path;
          _myPublicKey     = parsed.publicKey;
        });
      } catch (_) {}
    }

    final savedWl = await _settings.loadWhitelist();
    if (savedWl != null) {
      setState(() {
        _wlBytes   = savedWl.bytesList;
        _wlPaths   = savedWl.paths;
        _nicknames = _buildNicknames(_wlBytes, _wlPaths);
      });
    }

    final lastAddr = await _settings.getLastAddress();
    if (lastAddr != null && _serverCtrl.text.isEmpty) {
      setState(() => _serverCtrl.text = lastAddr);
    }
  }

  @override
  void dispose() {
    _serverCtrl.dispose();
    super.dispose();
  }

  Map<String, String> _buildNicknames(List<Uint8List> bytes, List<String> paths) {
    final result = <String, String>{};
    for (var i = 0; i < bytes.length; i++) {
      final hex = bytes[i].map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      var name = paths[i];
      if (name.toLowerCase().endsWith('.pub')) name = name.substring(0, name.length - 4);
      result[hex] = name;
    }
    return result;
  }

  Future<void> _pickPrivateKey() async {
    try {
      final result = await FilePicker.platform.pickFiles(type: FileType.any, withData: true, allowMultiple: false);
      if (result == null || result.files.isEmpty) return;
      final file = result.files.first;
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

  Future<void> _pickWhitelistFolder() async {
    try {
      final dirPath = await FilePicker.platform.getDirectoryPath();
      if (dirPath == null) return;
      final dir  = Directory(dirPath);
      final paths = <String>[];
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
      if (bytesList.isEmpty) { _setError('No valid ed25519 keys found in folder'); return; }
      await _settings.saveWhitelist(bytesList, paths);
      setState(() {
        _wlBytes   = bytesList;
        _wlPaths   = paths;
        _nicknames = _buildNicknames(bytesList, paths);
        _error     = null;
      });
      _tryApplyConfig();
    } catch (e) { _setError('Failed to load whitelist: $e'); }
  }

  Future<void> _pickWhitelistFiles() async {
    try {
      final result = await FilePicker.platform.pickFiles(type: FileType.any, withData: true, allowMultiple: true);
      if (result == null || result.files.isEmpty) return;
      final paths = <String>[];
      final bytesList = <Uint8List>[];
      for (final file in result.files) {
        final bytes = file.bytes;
        if (bytes == null) continue;
        final pubKey = tryParsePublicKeyFile(bytes);
        if (pubKey != null) { paths.add(file.name); bytesList.add(pubKey); }
      }
      if (bytesList.isEmpty) { _setError('No valid ed25519 keys found'); return; }
      await _settings.saveWhitelist(bytesList, paths);
      setState(() {
        _wlBytes   = bytesList;
        _wlPaths   = paths;
        _nicknames = _buildNicknames(bytesList, paths);
        _error     = null;
      });
      _tryApplyConfig();
    } catch (e) { _setError('Failed to load whitelist files: $e'); }
  }

  /// Remove one peer from whitelist.
  Future<void> _removePeer(int index) async {
    final newBytes = List<Uint8List>.from(_wlBytes)..removeAt(index);
    final newPaths = List<String>.from(_wlPaths)..removeAt(index);
    await _settings.saveWhitelist(newBytes, newPaths);
    setState(() {
      _wlBytes   = newBytes;
      _wlPaths   = newPaths;
      _nicknames = _buildNicknames(newBytes, newPaths);
    });
    _tryApplyConfig();
  }

  void _tryApplyConfig() {
    if (_privateKeyBytes == null || _myPublicKey == null) return;
    final server = _serverCtrl.text.trim();
    try {
      final parsed  = parseOpenSshPrivateKey(_privateKeyBytes!);
      final keyPair = makeKeyPair(parsed.seed, parsed.publicKey);
      final whitelist = _wlBytes.map((b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join()).toSet();
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Settings'), elevation: 0),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
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
          Card(
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
                      child: Text(_privateKeyPath ?? 'No key loaded',
                          style: theme.textTheme.bodyMedium?.copyWith(
                              color: _privateKeyPath != null
                                  ? theme.colorScheme.onSurface
                                  : theme.colorScheme.onSurfaceVariant),
                          overflow: TextOverflow.ellipsis),
                    ),
                    FilledButton.tonalIcon(
                      onPressed: _isLoading ? null : _pickPrivateKey,
                      icon: const Icon(Icons.file_open_outlined), label: const Text('Browse'),
                    ),
                  ]),
                  if (_myPublicKey != null) ...[
                    const SizedBox(height: 8),
                    const Divider(),
                    const SizedBox(height: 4),
                    Text('Your public key (share with peers):',
                        style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.primary)),
                    const SizedBox(height: 4),
                    Row(children: [
                      Expanded(
                        child: SelectableText(
                          _myPublicKey!.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
                          style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.copy, size: 16),
                        onPressed: () {
                          final hex = _myPublicKey!.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
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
          ),
          const SizedBox(height: 16),

          // ── Whitelist ────────────────────────────────────────────────────
          _sectionTitle('Trusted Peers (Whitelist)'),
          const SizedBox(height: 4),
          Text('Only listed keys can connect. Edit live — applies to new rooms.',
              style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant)),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: FilledButton.tonalIcon(
                onPressed: _pickWhitelistFolder,
                icon: const Icon(Icons.folder_open_outlined), label: const Text('Load Folder'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: FilledButton.tonalIcon(
                onPressed: _pickWhitelistFiles,
                icon: const Icon(Icons.file_present_outlined), label: const Text('Load Files'),
              ),
            ),
          ]),
          const SizedBox(height: 12),
          if (_wlBytes.isEmpty)
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                border: Border.all(color: theme.colorScheme.outlineVariant),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Center(
                child: Column(children: [
                  Icon(Icons.person_off_outlined, size: 40, color: theme.colorScheme.outlineVariant),
                  const SizedBox(height: 8),
                  const Text('No peers in whitelist'),
                ]),
              ),
            )
          else
            ...List.generate(_wlBytes.length, (i) {
              final hex  = _wlBytes[i].map((b) => b.toRadixString(16).padLeft(2, '0')).join();
              final nick = _nicknames[hex] ?? _wlPaths[i];
              return Card(
                margin: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                  leading: CircleAvatar(child: Text(nick.substring(0, 1).toUpperCase())),
                  title: Text(nick, style: const TextStyle(fontWeight: FontWeight.w500)),
                  subtitle: Text('${hex.substring(0, 16)}…',
                      style: const TextStyle(fontFamily: 'monospace', fontSize: 11)),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline, color: Colors.red),
                    onPressed: () => _showDeleteConfirm(i, nick),
                  ),
                ),
              );
            }),

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
          // ── About ─────────────────────────────────────────────────────────
          _sectionTitle('About'),
          const SizedBox(height: 8),
          _infoRow('App Version', '1.0.0'),
          _infoRow('Protocol', 'SGTP v1'),
        ],
      ),
    );
  }

  Widget _sectionTitle(String title) => Text(title,
      style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold));

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

  void _showDeleteConfirm(int index, String nick) {
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Remove Peer'),
        content: Text('Remove "$nick" from whitelist?\n\nThis applies to new rooms immediately.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          TextButton(
            onPressed: () { Navigator.pop(context); _removePeer(index); },
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
  }
}
