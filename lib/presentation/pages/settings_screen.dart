import 'dart:async';
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
import '../../core/sgtp_server_options.dart';
import '../../core/sgtp_transport.dart';
import '../../core/uuid_v7.dart';
import '../../data/repositories/settings_repository.dart';
import '../../data/sgtp_client.dart';
import '../../data/transport/server_discovery.dart';
import '../../domain/entities/node.dart';
import '../../core/app_logger.dart';
import '../../core/constants.dart';
import '../widgets/pretty_qr_share_panel.dart';
import '../widgets/qr_scanner_dialog.dart';
import 'logs_screen.dart';
import 'package:url_launcher/url_launcher.dart';

typedef ConfigChangedCallback = void Function(
    String accountId,
    SgtpConfig config,
    Map<String, String> nicknames,
    String serverAddress,
    List<WhitelistEntry> whitelistEntries);

typedef UserAvatarChangedCallback = void Function(Uint8List? avatar);

class SettingsScreen extends StatefulWidget {
  final SgtpConfig? initialConfig;
  final Map<String, String>? initialNicknames;
  final ConfigChangedCallback? onConfigChanged;
  final UserAvatarChangedCallback? onUserAvatarChanged;
  final Uint8List? currentUserAvatar;
  final void Function(String nickname)? onNicknameChanged;
  final void Function(String username)? onUsernameChanged;

  const SettingsScreen({
    super.key,
    this.initialConfig,
    this.initialNicknames,
    this.onConfigChanged,
    this.onUserAvatarChanged,
    this.currentUserAvatar,
    this.onNicknameChanged,
    this.onUsernameChanged,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _settings = SettingsRepository();
  final _serverCtrl = TextEditingController();
  final _nicknameCtrl = TextEditingController();
  final _usernameCtrl = TextEditingController();

  String? _privateKeyPath;
  Uint8List? _privateKeyBytes;
  Uint8List? _myPublicKey;

  List<WhitelistEntry> _wlEntries = [];
  Map<String, String> _nicknames = {};

  Uint8List? _userAvatar;
  String _nickname = '';
  final Map<String, Uint8List?> _avatarsByNodeId = {};
  final Map<String, String> _nicknamesByNodeId = {};

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

  // Accounts (formerly Nodes)
  List<NodeConfig> _nodes = const [];
  bool _nodesLoading = true;
  bool _accountsExpanded = false;
  String? _preferredNodeId;

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
    // Load nodes first so we know which account is active.
    final nodes = await _settings.loadNodes();
    final preferredNode = await _settings.loadPreferredNode();
    final preferredId =
        preferredNode?.id ?? (nodes.isNotEmpty ? nodes.first.id : null);

    if (preferredId != null && preferredId.trim().isNotEmpty) {
      await _settings.migrateLegacyAccountDataToNodeIfNeeded(preferredId);
    }

    if (mounted) {
      setState(() {
        _nodes = nodes;
        _nodesLoading = false;
        _preferredNodeId = preferredId;
        if (preferredNode != null) _serverCtrl.text = preferredNode.chatAddress;
      });
    }

    // Load account-scoped identity/profile/contacts for the active account.
    if (preferredId != null && preferredId.trim().isNotEmpty) {
      await _loadAccountData(preferredId, applyConfig: false);
    } else {
      final lastAddr = await _settings.getLastAddress();
      if (lastAddr != null && _serverCtrl.text.isEmpty) {
        setState(() => _serverCtrl.text = lastAddr);
      }
    }

    final mediaSettings = await _settings.loadMediaTransferSettings();

    // Load persisted prefs (nickname + interaction)
    final prefs = await SharedPreferences.getInstance();
    setState(() {
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

    unawaited(_refreshProfilesCache(nodes));
  }

  @override
  void dispose() {
    _serverCtrl.dispose();
    _nicknameCtrl.dispose();
    _usernameCtrl.dispose();
    super.dispose();
  }

  Map<String, String> _buildNicknames(List<WhitelistEntry> entries) {
    final result = <String, String>{};
    for (final e in entries) {
      result[e.hexKey] = e.name;
    }
    return result;
  }

  Future<void> _loadAccountData(String nodeId, {bool applyConfig = true}) async {
    // Profile (nickname + username + avatar)
    final nickname = await _settings.loadUserNicknameForNode(nodeId);
    final username = await _settings.loadUserUsernameForNode(nodeId);
    final avatar = await _settings.loadUserAvatarForNode(nodeId);

    // Identity key
    Uint8List? privBytes;
    String? privName;
    Uint8List? pubKey;
    final savedKey = await _settings.loadPrivateKeyForNode(nodeId);
    if (savedKey != null) {
      try {
        final parsed = parseOpenSshPrivateKey(savedKey.bytes);
        privBytes = savedKey.bytes;
        privName = savedKey.name;
        pubKey = parsed.publicKey;
      } catch (_) {}
    }

    // Contacts (whitelist)
    final entries = await _settings.loadWhitelistEntriesForNode(nodeId);

    if (!mounted) return;
    setState(() {
      _nickname = nickname;
      _nicknameCtrl.text = nickname;
      _usernameCtrl.text = username;
      _userAvatar = avatar;
      _avatarsByNodeId[nodeId] = avatar;
      _nicknamesByNodeId[nodeId] = nickname;

      _privateKeyBytes = privBytes;
      _privateKeyPath = privName;
      _myPublicKey = pubKey;

      _wlEntries = entries;
      _nicknames = _buildNicknames(entries);
    });

    widget.onUserAvatarChanged?.call(avatar);
    if (applyConfig) _tryApplyConfig();
  }

  Future<void> _refreshProfilesCache(List<NodeConfig> nodes) async {
    final nextAvatars = <String, Uint8List?>{};
    final nextNicks = <String, String>{};
    for (final n in nodes) {
      nextAvatars[n.id] = await _settings.loadUserAvatarForNode(n.id);
      nextNicks[n.id] = await _settings.loadUserNicknameForNode(n.id);
    }
    if (!mounted) return;
    setState(() {
      _avatarsByNodeId
        ..clear()
        ..addAll(nextAvatars);
      _nicknamesByNodeId
        ..clear()
        ..addAll(nextNicks);
    });
  }

  // ── Private key: browse ──────────────────────────────────────────────────

  Future<void> _pickPrivateKey() async {
    final nodeId = _preferredNodeId;
    if (nodeId == null || nodeId.trim().isEmpty) return;
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
      await _settings.savePrivateKeyForNode(nodeId, bytes, file.name);
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

  void _showPrivateKeyExportSheet() {
    final bytes = _privateKeyBytes;
    if (bytes == null || bytes.isEmpty) return;
    final keyText = utf8.decode(bytes, allowMalformed: true).trim();

    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.bgSurface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Export private key',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close,
                        color: AppColors.textSecondary),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              const Text(
                'Keep this secret. Anyone with this key can impersonate you.',
                style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
              ),
              const SizedBox(height: 16),
              Container(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(ctx).size.height * 0.45,
                ),
                width: double.infinity,
                decoration: BoxDecoration(
                  color: AppColors.bgMain,
                  border: Border.all(color: AppColors.border),
                  borderRadius: BorderRadius.circular(12),
                ),
                padding: const EdgeInsets.all(12),
                child: SingleChildScrollView(
                  child: SelectableText(
                    keyText,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                      color: AppColors.textPrimary,
                      height: 1.25,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: keyText));
                    Navigator.pop(ctx);
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Private key copied')),
                    );
                  },
                  icon: const Icon(Icons.content_copy),
                  label: const Text('Copy'),
                  style: ButtonStyle(
                    minimumSize:
                        const WidgetStatePropertyAll(Size.fromHeight(48)),
                    shape: WidgetStatePropertyAll(
                      RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                    backgroundColor:
                        const WidgetStatePropertyAll(AppColors.accent),
                    foregroundColor:
                        const WidgetStatePropertyAll(Colors.black),
                    overlayColor:
                        WidgetStatePropertyAll(Colors.white.withAlpha(20)),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _importPrivateKeyFromClipboard() async {
    final nodeId = _preferredNodeId;
    if (nodeId == null || nodeId.trim().isEmpty) return;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Are you sure?'),
        content: const Text(
            'Importing a key from clipboard will REPLACE the private key for this account.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('No'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.orange),
            child: const Text('Yes'),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    if (text.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Clipboard is empty')),
      );
      return;
    }

    try {
      final bytes = Uint8List.fromList(text.codeUnits);
      final parsed = parseOpenSshPrivateKey(bytes);
      await _settings.savePrivateKeyForNode(nodeId, bytes, 'clipboard_identity');
      if (!mounted) return;
      setState(() {
        _privateKeyBytes = bytes;
        _privateKeyPath = 'clipboard_identity';
        _myPublicKey = parsed.publicKey;
        _error = null;
      });
      _tryApplyConfig();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Private key imported from clipboard')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Invalid private key: $e')),
      );
    }
  }

  Future<bool> _pickPrivateKeyForAccount(String nodeId) async {
    try {
      final result = await FilePicker.platform
          .pickFiles(type: FileType.any, withData: true, allowMultiple: false);
      if (result == null || result.files.isEmpty) return false;
      final file = result.files.first;
      final bytes = file.bytes;
      if (bytes == null) return false;
      // Validate
      parseOpenSshPrivateKey(bytes);
      await _settings.savePrivateKeyForNode(nodeId, bytes, file.name);
      return true;
    } catch (_) {
      return false;
    }
  }

  // ── Private key: generate ────────────────────────────────────────────────

  Future<void> _generatePrivateKey() async {
    final nodeId = _preferredNodeId;
    if (nodeId == null || nodeId.trim().isEmpty) return;
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
      await _settings.savePrivateKeyForNode(nodeId, opensshBytes, name);

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

  Future<bool> _generatePrivateKeyForAccount(String nodeId) async {
    try {
      final algorithm = Ed25519();
      final keyPair = await algorithm.newKeyPair();
      final pubKey = await keyPair.extractPublicKey();
      final privBytes = await keyPair.extractPrivateKeyBytes();
      final pubBytes = Uint8List.fromList(pubKey.bytes);
      final opensshBytes = _encodeOpenSshPrivateKey(privBytes, pubBytes);
      await _settings.savePrivateKeyForNode(nodeId, opensshBytes, 'identity');
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _pastePrivateKeyForAccount(String nodeId, String text) async {
    try {
      final bytes = Uint8List.fromList(text.codeUnits);
      // Validate
      parseOpenSshPrivateKey(bytes);
      await _settings.savePrivateKeyForNode(nodeId, bytes, 'pasted_identity');
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _promptPrivateKeyForAccount(String nodeId) async {
    final existing = await _settings.loadPrivateKeyForNode(nodeId);
    if (existing != null) return true;

    bool saved = false;
    String? error;
    final pasteCtrl = TextEditingController();
    if (!mounted) return false;

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.bgSurface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => SafeArea(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
                20, 24, 20, MediaQuery.of(ctx).viewInsets.bottom + 24),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'Private key',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w600,
                            color: AppColors.textPrimary,
                          ),
                        ),
                      ),
                      GestureDetector(
                        onTap: () => Navigator.pop(ctx),
                        child: const Icon(Icons.close,
                            color: AppColors.textSecondary, size: 22),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Select or generate an Ed25519 private key for this account.',
                    style:
                        TextStyle(fontSize: 13, color: AppColors.textSecondary),
                  ),
                  const SizedBox(height: 20),

                  // Browse
                  _SheetBtn(
                    label: 'Browse file',
                    icon: Icons.folder_open_outlined,
                    onTap: () async {
                      final ok = await _pickPrivateKeyForAccount(nodeId);
                      if (!ctx.mounted) return;
                      if (ok) {
                        saved = true;
                        Navigator.pop(ctx);
                      } else {
                        setS(() => error = 'Invalid or unreadable key file');
                      }
                    },
                  ),
                  const SizedBox(height: 16),
                  _OrDivider(),
                  const SizedBox(height: 16),

                  // Generate
                  _SheetBtn(
                    label: 'Generate key',
                    icon: Icons.key_outlined,
                    secondary: true,
                    onTap: () async {
                      final ok = await _generatePrivateKeyForAccount(nodeId);
                      if (!ctx.mounted) return;
                      if (ok) {
                        saved = true;
                        Navigator.pop(ctx);
                      } else {
                        setS(() => error = 'Key generation failed');
                      }
                    },
                  ),
                  const SizedBox(height: 16),
                  _OrDivider(),
                  const SizedBox(height: 16),

                  // Paste field
                  Container(
                    decoration: BoxDecoration(
                      color: AppColors.bgSurfaceActive,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                          color: error != null
                              ? AppColors.statusRed
                              : AppColors.border),
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: TextField(
                      controller: pasteCtrl,
                      maxLines: 6,
                      style: const TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 13,
                        fontFamily: 'monospace',
                      ),
                      decoration: const InputDecoration(
                        hintText:
                            '-----BEGIN OPENSSH PRIVATE KEY-----\n…',
                        hintStyle: TextStyle(
                            color: AppColors.textSecondary, fontSize: 13),
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        isDense: true,
                        contentPadding: EdgeInsets.symmetric(vertical: 14),
                      ),
                      onChanged: (_) => setS(() => error = null),
                    ),
                  ),
                  if (error != null) ...[
                    const SizedBox(height: 6),
                    Padding(
                      padding: const EdgeInsets.only(left: 4),
                      child: Text(error!,
                          style: const TextStyle(
                              fontSize: 12, color: AppColors.statusRed)),
                    ),
                  ],
                  const SizedBox(height: 12),
                  _SheetBtn(
                    label: 'Import key',
                    icon: Icons.content_paste_outlined,
                    secondary: true,
                    onTap: () async {
                      final text = pasteCtrl.text.trim();
                      if (text.isEmpty) return;
                      final ok =
                          await _pastePrivateKeyForAccount(nodeId, text);
                      if (!ctx.mounted) return;
                      if (ok) {
                        saved = true;
                        Navigator.pop(ctx);
                      } else {
                        setS(
                            () => error = 'Invalid private key (OpenSSH format)');
                      }
                    },
                  ),
                  const SizedBox(height: 16),
                  _SheetBtn(
                    label: 'Later',
                    secondary: true,
                    onTap: () => Navigator.pop(ctx),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    pasteCtrl.dispose();
    return saved;
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
      final nodeId = _preferredNodeId;
      if (nodeId == null || nodeId.trim().isEmpty) return;
      await _settings.saveWhitelistEntriesForNode(nodeId, entries);
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
      final nodeId = _preferredNodeId;
      if (nodeId == null || nodeId.trim().isEmpty) return;
      await _settings.saveWhitelistEntriesForNode(nodeId, combined);
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
    final nodeId = _preferredNodeId;
    if (nodeId == null || nodeId.trim().isEmpty) return;
    await _settings.saveWhitelistEntriesForNode(nodeId, combined);
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
    final nodeId = _preferredNodeId;
    if (nodeId == null || nodeId.trim().isEmpty) return;
    await _settings.saveWhitelistEntriesForNode(nodeId, updated);
    setState(() {
      _wlEntries = updated;
      _nicknames = _buildNicknames(updated);
    });
    _tryApplyConfig();
  }

  // ── Whitelist: remove ─────────────────────────────────────────────────────

  Future<void> _removeEntry(int index) async {
    final newList = List<WhitelistEntry>.from(_wlEntries)..removeAt(index);
    final nodeId = _preferredNodeId;
    if (nodeId == null || nodeId.trim().isEmpty) return;
    await _settings.saveWhitelistEntriesForNode(nodeId, newList);
    setState(() {
      _wlEntries = newList;
      _nicknames = _buildNicknames(newList);
    });
    _tryApplyConfig();
  }

  // ── User avatar ───────────────────────────────────────────────────────────

  Future<void> _pickUserAvatar() async {
    final nodeId = _preferredNodeId;
    if (nodeId == null || nodeId.trim().isEmpty) return;
    final picker = ImagePicker();
    final file = await picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 512,
      maxHeight: 512,
      imageQuality: 80,
    );
    if (file == null) return;
    final bytes = await file.readAsBytes();
    await _settings.saveUserAvatarForNode(nodeId, bytes);
    setState(() {
      _userAvatar = bytes;
      _error = null;
    });
    widget.onUserAvatarChanged?.call(bytes);
    _avatarsByNodeId[nodeId] = bytes;
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Avatar saved')),
      );
    }
  }

  Future<void> _removeUserAvatar() async {
    final nodeId = _preferredNodeId;
    if (nodeId == null || nodeId.trim().isEmpty) return;
    await _settings.clearUserAvatarForNode(nodeId);
    setState(() => _userAvatar = null);
    widget.onUserAvatarChanged?.call(null);
    _avatarsByNodeId[nodeId] = null;
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
      final accountId = _preferredNodeId;
      if (accountId == null || accountId.trim().isEmpty) return;
      final node =
          _nodes.where((n) => n.id == accountId).firstOrNull;
      final newConfig = SgtpConfig(
        serverAddr: server.isEmpty ? 'localhost:7777' : server,
        roomUUID: Uint8List(16),
        identityKeyPair: keyPair,
        myPublicKey: parsed.publicKey,
        whitelist: whitelist,
        transport: node?.transport ?? SgtpTransportFamily.tcp,
        useTls: node?.useTls ?? false,
        nodeId: accountId,
        pingIntervalSeconds: _pingIntervalSeconds,
        mediaChunkSizeBytes: _mediaChunkSizeBytes,
      );
      widget.onConfigChanged
          ?.call(accountId, newConfig, _nicknames, server, _wlEntries);
    } catch (e) {
      _setError('Config error: $e');
    }
  }

  void _setError(String msg) => setState(() => _error = msg);

  // ── Connection address ────────────────────────────────────────────────────

  Future<void> _saveConnectionAddress(String value) async {
    _tryApplyConfig();
    if (_preferredNodeId == null) return;
    final raw = value.trim()
        .replaceAll(RegExp(r'^https?://', caseSensitive: false), '')
        .replaceAll(RegExp(r'^wss?://', caseSensitive: false), '')
        .trim();
    final parsed = _parseHostPort(raw);
    if (parsed == null) return;
    final (host, port) = parsed;
    final nodeIdx = _nodes.indexWhere((n) => n.id == _preferredNodeId);
    if (nodeIdx < 0) return;
    final updated = _nodes[nodeIdx].copyWith(
      host: host,
      chatPort: port ?? _nodes[nodeIdx].chatPort,
      voicePort: port ?? _nodes[nodeIdx].voicePort,
    );
    await _settings.upsertNode(updated);
    await _reloadNodes();
  }

  InputDecoration _darkFieldDeco({
    required String label,
    required String hint,
    required IconData icon,
  }) {
    return InputDecoration(
      labelText: label,
      labelStyle: const TextStyle(color: AppColors.textSecondary),
      hintText: hint,
      hintStyle: const TextStyle(color: AppColors.textSecondary),
      prefixIcon: Icon(icon, color: AppColors.textSecondary),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: AppColors.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: AppColors.accentBlue),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: AppColors.statusRed),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: AppColors.statusRed),
      ),
      filled: true,
      fillColor: AppColors.bgSurfaceActive,
    );
  }

  // ── Nodes ────────────────────────────────────────────────────────────────

  Future<void> _reloadNodes() async {
    final nodes = await _settings.loadNodes();
    final preferred = await _settings.loadPreferredNode();
    if (!mounted) return;
    setState(() {
      _nodes = nodes;
      _nodesLoading = false;
      _preferredNodeId = preferred?.id ?? (nodes.isNotEmpty ? nodes.first.id : null);
    });
    unawaited(_refreshProfilesCache(nodes));
  }

  Future<NodeConfig?> _openNodeEditor({NodeConfig? existing}) async {
    final baseId = existing?.id ?? uuidBytesToHex(generateUUIDv7());

    final nameCtrl = TextEditingController(text: existing?.name ?? '');
    final hostCtrl = TextEditingController(text: existing?.host ?? '');
    final chatCtrl = TextEditingController(
        text: existing != null ? existing.chatPort.toString() : '');
    final voiceCtrl = TextEditingController(
        text: existing != null ? existing.voicePort.toString() : '');

    var transport = existing?.transport ?? SgtpTransportFamily.tcp;
    var useTls = existing?.useTls ?? false;
    SgtpServerOptions? serverOptions =
        existing != null ? await _settings.loadNodeServerOptions(baseId) : null;
    DateTime? serverOptionsAt = existing != null
        ? await _settings.loadNodeServerOptionsSavedAt(baseId)
        : null;
    var optionsLoading = false;
    String? optionsError;

    NodeConfig? result;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.bgSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(
              20, 20, 20, MediaQuery.of(ctx).viewInsets.bottom + 20),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        existing == null ? 'Add Account' : 'Edit Account',
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                          color: AppColors.textPrimary,
                        ),
                      ),
                    ),
                    GestureDetector(
                      onTap: () => Navigator.of(ctx).pop(),
                      child: const Icon(Icons.close,
                          color: AppColors.textSecondary, size: 22),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                _StyledField(
                  controller: nameCtrl,
                  icon: Icons.badge_outlined,
                  hint: 'Account name',
                ),
                const SizedBox(height: 12),
                _StyledField(
                  controller: hostCtrl,
                  icon: Icons.dns_outlined,
                  hint: 'example.com',
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: _StyledField(
                        controller: chatCtrl,
                        icon: Icons.chat_bubble_outline,
                        hint: 'Discovery port',
                        keyboardType: TextInputType.number,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _StyledField(
                        controller: voiceCtrl,
                        icon: Icons.mic_none_outlined,
                        hint: 'Voice port',
                        keyboardType: TextInputType.number,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                StatefulBuilder(builder: (ctx, setModalState) {
                  bool tlsAvailable() =>
                      serverOptions?.supports(transport, tls: true) == true;
                  if (useTls && !tlsAvailable()) useTls = false;

                  Future<void> refreshOptions() async {
                    final host = hostCtrl.text
                        .trim()
                        .replaceAll(
                            RegExp(r'^https?://', caseSensitive: false), '')
                        .replaceAll(
                            RegExp(r'^wss?://', caseSensitive: false), '')
                        .trim();
                    final discoveryPort = int.tryParse(chatCtrl.text.trim());
                    if (host.isEmpty ||
                        discoveryPort == null ||
                        discoveryPort <= 0 ||
                        discoveryPort > 65535) {
                      setModalState(() {
                        optionsError = 'Enter a valid host and discovery port';
                      });
                      return;
                    }

                    setModalState(() {
                      optionsLoading = true;
                      optionsError = null;
                    });
                    try {
                      final opts = await SgtpServerDiscovery.discover(
                          host, discoveryPort);
                      await _settings.saveNodeServerOptions(baseId, opts);
                      final savedAt =
                          await _settings.loadNodeServerOptionsSavedAt(baseId);
                      setModalState(() {
                        serverOptions = opts;
                        serverOptionsAt = savedAt ?? DateTime.now();
                        optionsLoading = false;
                        optionsError = null;
                        if (useTls && !tlsAvailable()) useTls = false;
                      });
                    } catch (e) {
                      setModalState(() {
                        optionsLoading = false;
                        optionsError = 'Failed to fetch options: $e';
                      });
                    }
                  }

                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: DropdownButtonFormField<SgtpTransportFamily>(
                              value: transport,
                              items: const [
                                DropdownMenuItem(
                                  value: SgtpTransportFamily.tcp,
                                  child: Text('TCP'),
                                ),
                                DropdownMenuItem(
                                  value: SgtpTransportFamily.http,
                                  child: Text('HTTP'),
                                ),
                                DropdownMenuItem(
                                  value: SgtpTransportFamily.websocket,
                                  child: Text('WebSocket'),
                                ),
                              ],
                              onChanged: (v) {
                                if (v == null) return;
                                setModalState(() {
                                  transport = v;
                                  if (useTls && !tlsAvailable()) useTls = false;
                                });
                              },
                              decoration: const InputDecoration(
                                labelText: 'Transport',
                                border: OutlineInputBorder(),
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: CheckboxListTile(
                              value: useTls,
                              onChanged: tlsAvailable()
                                  ? (v) =>
                                      setModalState(() => useTls = v ?? false)
                                  : null,
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              title: const Text('TLS'),
                              controlAffinity: ListTileControlAffinity.leading,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: optionsLoading ? null : refreshOptions,
                              icon: optionsLoading
                                  ? const SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2),
                                    )
                                  : const Icon(Icons.sync),
                              label: const Text('Fetch server options'),
                            ),
                          ),
                        ],
                      ),
                      if (optionsError != null) ...[
                        const SizedBox(height: 6),
                        Text(
                          optionsError!,
                          style: const TextStyle(color: AppColors.statusRed),
                        ),
                      ],
                      if (serverOptions != null) ...[
                        const SizedBox(height: 6),
                        Text(
                          'Available: ${serverOptions!.availableLabels().join(", ")}'
                          '${serverOptionsAt != null ? " (cached)" : ""}',
                          style: const TextStyle(
                              color: AppColors.textSecondary, fontSize: 12),
                        ),
                      ],
                    ],
                  );
                }),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: _SheetBtn(
                        label: 'Cancel',
                        secondary: true,
                        onTap: () => Navigator.of(ctx).pop(),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _SheetBtn(
                        label: 'Save',
                        onTap: () {
                          final name = nameCtrl.text.trim();
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

                          bool validPort(int? p) =>
                              p != null && p > 0 && p <= 65535;
                          if (name.isEmpty ||
                              host.isEmpty ||
                              !validPort(chatPort) ||
                              !validPort(voicePort)) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text(
                                    'Please fill in all fields with valid values'),
                              ),
                            );
                            return;
                          }

                          result = NodeConfig(
                            id: baseId,
                            name: name,
                            host: host,
                            chatPort: chatPort!,
                            voicePort: voicePort!,
                            transport: transport,
                            useTls: useTls,
                          );
                          Navigator.of(ctx).pop();
                        },
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
    return result;
  }

  Future<void> _addNode() async {
    final node = await _openNodeEditor();
    if (node == null) return;
    await _settings.upsertNode(node);
    await _reloadNodes();
    _tryApplyConfig();
    if (!mounted) return;
    final ok = await _promptPrivateKeyForAccount(node.id);
    if (!mounted) return;
    if (ok) {
      await _selectAccount(node);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Account added without private key')),
      );
    }
  }

  Future<void> _editNode(NodeConfig node) async {
    final updated = await _openNodeEditor(existing: node);
    if (updated == null) return;
    await _settings.upsertNode(updated);
    await _reloadNodes();
    _tryApplyConfig();
  }

  Future<void> _deleteNode(NodeConfig node) async {
    bool confirmed = false;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.bgSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Delete Account?',
                style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary),
              ),
              const SizedBox(height: 12),
              RichText(
                text: TextSpan(
                  style: const TextStyle(
                      fontSize: 15,
                      color: AppColors.textSecondary,
                      height: 1.5),
                  children: [
                    const TextSpan(text: 'Remove '),
                    TextSpan(
                      text: node.name,
                      style: const TextStyle(
                          color: AppColors.textPrimary,
                          fontWeight: FontWeight.w600),
                    ),
                    TextSpan(
                        text: ' (${node.chatAddress}) from your accounts?'),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(
                    child: _SheetBtn(
                      label: 'Cancel',
                      secondary: true,
                      onTap: () => Navigator.pop(ctx),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _SheetBtn(
                      label: 'Delete',
                      danger: true,
                      onTap: () {
                        confirmed = true;
                        Navigator.pop(ctx);
                      },
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    if (!confirmed) return;
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
          _buildAccountSwitcher(),
          _buildProfileSection(),
          _SettingsGroup(title: 'Connection', child: _buildConnectionCard()),
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
    final nodeId = _preferredNodeId;
    if (nodeId == null || nodeId.trim().isEmpty) return;
    final next = value.trim();
    await _settings.saveUserNicknameForNode(nodeId, next);
    if (!mounted) return;
    setState(() => _nickname = next);
    _nicknamesByNodeId[nodeId] = next;
    widget.onNicknameChanged?.call(next);
  }

  Future<void> _saveUsername(String value) async {
    final nodeId = _preferredNodeId;
    if (nodeId == null || nodeId.trim().isEmpty) return;
    // Strip leading @ if user typed it, sanitize
    final stripped = value.trim().replaceFirst(RegExp(r'^@'), '');
    final sanitized =
        stripped.replaceAll(RegExp(r'[^A-Za-z0-9_]'), '').substring(
              0,
              stripped.replaceAll(RegExp(r'[^A-Za-z0-9_]'), '').length.clamp(0, 32),
            );
    await _settings.saveUserUsernameForNode(nodeId, sanitized);
    if (!mounted) return;
    widget.onUsernameChanged?.call(sanitized);
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

  void _showNodeShare(NodeConfig node) {
    final shareData = QrShareData(
      type: 'node',
      serverAddress: node.chatAddress,
      nodeId: node.id,
      nodeName: node.name,
      nodeHost: node.host,
      nodeChatPort: node.chatPort,
      nodeVoicePort: node.voicePort,
      timestamp: DateTime.now().millisecondsSinceEpoch,
    );

    final safeName = node.name
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');

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
          title: node.name,
          subtitle: node.chatAddress,
          description:
              'Share this so others can add the node without typing it manually.',
          copyMessage: 'Node hex copied',
          exportName: safeName.isEmpty ? 'node' : 'node-$safeName',
        ),
      ),
    );
  }

  Future<void> _importNodeFromQr() async {
    final data = await Navigator.push<QrShareData>(
      context,
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => const QrScannerDialog(),
      ),
    );
    if (!mounted || data == null) return;
    final node = await _importNodeFromShareData(data);
    if (!mounted || node == null) return;
    final ok = await _promptPrivateKeyForAccount(node.id);
    if (!mounted) return;
    if (ok) {
      await _selectAccount(node);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Account imported without private key')),
      );
    }
  }

  Future<void> _showNodeHexImportSheet() async {
    final inputCtrl = TextEditingController();
    String? errorMsg;

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.bgSurface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => Padding(
          padding: EdgeInsets.fromLTRB(
              20, 24, 20, MediaQuery.of(ctx).viewInsets.bottom + 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Import Node',
                      style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w600,
                          color: AppColors.textPrimary)),
                  IconButton(
                    icon:
                        const Icon(Icons.close, color: AppColors.textSecondary),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              const Text(
                'Paste node share hex (or base64). You can also paste a raw host:port.',
                style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: inputCtrl,
                maxLines: 4,
                decoration: InputDecoration(
                  hintText: 'Node share hex / base64 / host:port…',
                  border: const OutlineInputBorder(),
                  errorText: errorMsg,
                ),
                autocorrect: false,
                enableSuggestions: false,
                textCapitalization: TextCapitalization.none,
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('Cancel'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: () async {
                        final raw = inputCtrl.text.trim();
                        if (raw.isEmpty) return;

                        final data = QrShareData.parse(raw);
                        if (data != null) {
                          final node = await _importNodeFromShareData(data);
                          if (!ctx.mounted) return;
                          if (node != null) {
                            Navigator.pop(ctx);
                            final ok =
                                await _promptPrivateKeyForAccount(node.id);
                            if (!mounted) return;
                            if (ok) {
                              await _selectAccount(node);
                            } else {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                    content: Text(
                                        'Account imported without private key')),
                              );
                            }
                          }
                          return;
                        }

                        final parsed = _parseHostPort(raw);
                        if (parsed == null) {
                          setS(() => errorMsg =
                              'Could not parse — paste node share hex/base64 or host:port');
                          return;
                        }

                        final (host, port) = parsed;
                        final chatPort = port ?? 7777;
                        if (chatPort <= 0 || chatPort > 65535) {
                          setS(() =>
                              errorMsg = 'Port must be in range 1–65535');
                          return;
                        }
                        final node = NodeConfig(
                          id: uuidBytesToHex(generateUUIDv7()),
                          name: host,
                          host: host,
                          chatPort: chatPort,
                          voicePort: chatPort,
                        );
                        await _settings.upsertNode(node);
                        await _reloadNodes();
                        if (!mounted) return;
                        if (ctx.mounted) Navigator.pop(ctx);
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                              content: Text('Node imported: ${node.chatAddress}')),
                        );
                        final ok =
                            await _promptPrivateKeyForAccount(node.id);
                        if (!mounted) return;
                        if (ok) {
                          await _selectAccount(node);
                        } else {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                                content:
                                    Text('Account imported without private key')),
                          );
                        }
                      },
                      child: const Text('Import'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );

    inputCtrl.dispose();
  }

  (String, int?)? _parseHostPort(String raw) {
    final normalized = raw
        .trim()
        .replaceAll(RegExp(r'^https?://', caseSensitive: false), '')
        .replaceAll(RegExp(r'^wss?://', caseSensitive: false), '')
        .trim();
    if (normalized.isEmpty) return null;

    // IPv6 in brackets: [::1]:7777
    if (normalized.startsWith('[')) {
      final end = normalized.indexOf(']');
      if (end <= 1) return null;
      final host = normalized.substring(1, end).trim();
      if (host.isEmpty) return null;
      final rest = normalized.substring(end + 1).trim();
      if (rest.isEmpty) return (host, null);
      if (!rest.startsWith(':')) return null;
      final port = int.tryParse(rest.substring(1).trim());
      if (port == null) return null;
      return (host, port);
    }

    final idx = normalized.lastIndexOf(':');
    if (idx <= 0 || idx == normalized.length - 1) return (normalized, null);
    final host = normalized.substring(0, idx).trim();
    final port = int.tryParse(normalized.substring(idx + 1).trim());
    if (port == null) return null;
    return (host, port);
  }

  Future<NodeConfig?> _importNodeFromShareData(QrShareData data) async {
    final node = _nodeFromQrShareData(data);
    if (node == null) {
      if (!mounted) return null;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Invalid node QR/hex')),
      );
      return null;
    }
    await _settings.upsertNode(node);
    await _reloadNodes();
    if (!mounted) return node;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Node imported: ${node.chatAddress}')),
    );
    return node;
  }

  NodeConfig? _nodeFromQrShareData(QrShareData data) {
    if (data.type != 'node') return null;

    bool validPort(int? p) => p != null && p > 0 && p <= 65535;

    String normalizeHost(String host) => host
        .trim()
        .replaceAll(RegExp(r'^https?://', caseSensitive: false), '')
        .replaceAll(RegExp(r'^wss?://', caseSensitive: false), '')
        .trim();

    final id = (data.nodeId ?? '').trim().isNotEmpty
        ? data.nodeId!.trim()
        : uuidBytesToHex(generateUUIDv7());

    String? host = data.nodeHost != null ? normalizeHost(data.nodeHost!) : null;
    int? chatPort = data.nodeChatPort;

    if ((host == null || host.isEmpty) && data.serverAddress != null) {
      final parsed = _parseHostPort(data.serverAddress!);
      if (parsed != null) {
        host = parsed.$1;
        chatPort ??= parsed.$2;
      }
    }

    host = host?.trim();
    chatPort ??= 7777;
    final voicePort = data.nodeVoicePort ?? chatPort;

    if (host == null ||
        host.isEmpty ||
        !validPort(chatPort) ||
        !validPort(voicePort)) {
      return null;
    }

    final name = (data.nodeName ?? host).trim().isEmpty
        ? 'Node'
        : (data.nodeName ?? host).trim();

    return NodeConfig(
      id: id,
      name: name,
      host: host,
      chatPort: chatPort,
      voicePort: voicePort,
    );
  }

  Widget _buildProfileSection() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 32, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // ── Avatar ──────────────────────────────────────────────────────
          GestureDetector(
            onTap: _pickUserAvatar,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Container(
                  width: 88,
                  height: 88,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: AppColors.bgSurface,
                    border: Border.all(color: AppColors.border),
                    image: _userAvatar != null
                        ? DecorationImage(
                            image: MemoryImage(_userAvatar!),
                            fit: BoxFit.cover)
                        : null,
                  ),
                  child: _userAvatar == null
                      ? const Icon(Icons.person,
                          size: 40, color: AppColors.textSecondary)
                      : null,
                ),
                Positioned(
                  bottom: -2,
                  right: -2,
                  child: Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: const Color(0xFF222226),
                      border: Border.all(color: AppColors.bgMain, width: 2),
                    ),
                    child: const Icon(Icons.photo_camera,
                        size: 18, color: AppColors.textPrimary),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),

          // ── Nickname input ───────────────────────────────────────────────
          TextField(
            controller: _nicknameCtrl,
            onChanged: _saveNickname,
            onSubmitted: _saveNickname,
            cursorColor: AppColors.textPrimary,
            style: const TextStyle(
                color: AppColors.textPrimary,
                fontSize: 16,
                fontWeight: FontWeight.w500),
            decoration: InputDecoration(
              hintText: 'Display Name',
              hintStyle: const TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 16,
                  fontWeight: FontWeight.w400),
              prefixIcon: const Icon(Icons.person_outline,
                  size: 22, color: AppColors.textSecondary),
              suffixIcon: const Icon(Icons.edit_outlined,
                  size: 18, color: AppColors.textSecondary),
              filled: true,
              fillColor: const Color(0xFF1B1B1F),
              hoverColor: Colors.transparent,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: AppColors.border),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: AppColors.border),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: AppColors.textSecondary),
              ),
              contentPadding: const EdgeInsets.symmetric(vertical: 14),
            ),
          ),
          const SizedBox(height: 12),

          // ── Username input ───────────────────────────────────────────────
          TextField(
            controller: _usernameCtrl,
            onChanged: _saveUsername,
            onSubmitted: _saveUsername,
            cursorColor: AppColors.textPrimary,
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9_@]')),
            ],
            style: const TextStyle(
                color: AppColors.textPrimary,
                fontSize: 16,
                fontWeight: FontWeight.w500),
            decoration: InputDecoration(
              hintText: 'username',
              hintStyle: const TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 16,
                  fontWeight: FontWeight.w400),
              prefixIcon: const Icon(Icons.alternate_email,
                  size: 22, color: AppColors.textSecondary),
              suffixIcon: const Icon(Icons.edit_outlined,
                  size: 18, color: AppColors.textSecondary),
              filled: true,
              fillColor: const Color(0xFF1B1B1F),
              hoverColor: Colors.transparent,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: AppColors.border),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: AppColors.border),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: AppColors.textSecondary),
              ),
              contentPadding: const EdgeInsets.symmetric(vertical: 14),
            ),
          ),
          const SizedBox(height: 16),

          // ── Share Profile button ─────────────────────────────────────────
          GestureDetector(
            onTap: _showMyProfileShare,
            child: Container(
              height: 48,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.ios_share_outlined, size: 20, color: Colors.black),
                  SizedBox(width: 8),
                  Text(
                    'Share Profile',
                    style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: Colors.black),
                  ),
                ],
              ),
            ),
          ),

          // ── Remove avatar ────────────────────────────────────────────────
          if (_userAvatar != null) ...[
            const SizedBox(height: 16),
            GestureDetector(
              onTap: _removeUserAvatar,
              child: const Text(
                'Remove avatar',
                style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: Color(0xFFFF453A)),
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ── Account switcher ─────────────────────────────────────────────────────

  Widget _buildAccountSwitcher() {
    final active = _nodes.firstWhere(
      (n) => n.id == _preferredNodeId,
      orElse: () => _nodes.isNotEmpty
          ? _nodes.first
          : NodeConfig(
              id: '', name: '', host: '', chatPort: 7777,
              voicePort: 7777),
    );
    final hasAccounts = _nodes.isNotEmpty;

    return Container(
      decoration: const BoxDecoration(
        color: AppColors.bgSurface,
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: Column(
        children: [
          // ── Header row ─────────────────────────────────────────────────
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => setState(() => _accountsExpanded = !_accountsExpanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
              child: Row(
                children: [
                  // Use profile avatar + nickname instead of node data
                  _AccAvatarImage(
                    avatar: _userAvatar,
                    name: _nickname.isNotEmpty
                        ? _nickname
                        : (hasAccounts ? active.name : ''),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _nodesLoading
                        ? const Text('Loading…',
                            style: TextStyle(
                                fontSize: 15, color: AppColors.textSecondary))
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _nickname.isNotEmpty
                                    ? _nickname
                                    : (hasAccounts ? active.name : 'No accounts'),
                                style: const TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                  color: AppColors.textPrimary,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                              if (hasAccounts) ...[
                                const SizedBox(height: 2),
                                Text(
                                  active.chatAddress,
                                  style: const TextStyle(
                                      fontSize: 13,
                                      color: AppColors.textSecondary),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ],
                          ),
                  ),
                  const SizedBox(width: 12),
                  AnimatedRotation(
                    turns: _accountsExpanded ? 0.5 : 0,
                    duration: const Duration(milliseconds: 250),
                    curve: Curves.easeInOut,
                    child: const Icon(Icons.expand_more,
                        color: AppColors.textSecondary, size: 24),
                  ),
                ],
              ),
            ),
          ),
          // ── Dropdown ───────────────────────────────────────────────────
          if (_accountsExpanded) ...[
            const Divider(height: 1, thickness: 1, color: AppColors.border),
            Column(
              children: [
                ..._nodes.map((n) => _AccountDropdownItem(
                      node: n,
                      isActive: n.id == _preferredNodeId,
                      profileAvatar: _avatarsByNodeId[n.id],
                      profileName: _nicknamesByNodeId[n.id],
                      onTap: () => unawaited(_selectAccount(n)),
                      onShare: () => _showNodeShare(n),
                      onDelete: () => _deleteNode(n),
                    )),
                // ── Add Account ───────────────────────────────────────
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {
                    setState(() => _accountsExpanded = false);
                    _showAddAccountSheet();
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 20, vertical: 12),
                    child: Row(
                      children: [
                        Container(
                          width: 42,
                          height: 42,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(color: AppColors.textSecondary),
                          ),
                          child: const Icon(Icons.add,
                              color: AppColors.textSecondary, size: 22),
                        ),
                        const SizedBox(width: 12),
                        const Text(
                          'Add Account',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w500,
                            color: AppColors.textPrimary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _selectAccount(NodeConfig node) async {
    setState(() {
      _preferredNodeId = node.id;
      _serverCtrl.text = node.chatAddress;
      _accountsExpanded = false;
    });
    await _settings.setLastNodeId(node.id);
    await _loadAccountData(node.id, applyConfig: true);
  }

  void _showAddAccountSheet() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.bgSurface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Add Account',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 20),
              _AddAccountOption(
                icon: Icons.qr_code_scanner_outlined,
                title: 'Scan QR',
                subtitle: 'Import an account by scanning its QR code',
                onTap: () {
                  Navigator.pop(context);
                  _importNodeFromQr();
                },
              ),
              const SizedBox(height: 12),
              _AddAccountOption(
                icon: Icons.edit_note_outlined,
                title: 'Enter Manually',
                subtitle: 'Fill in the server address and ports by hand',
                onTap: () {
                  Navigator.pop(context);
                  _addNode();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Connection card ───────────────────────────────────────────────────────

  Widget _buildConnectionCard() {
    return Row(
      children: [
        const Icon(Icons.dns_outlined, size: 22, color: AppColors.textSecondary),
        const SizedBox(width: 12),
        Expanded(
          child: TextField(
            controller: _serverCtrl,
            onChanged: (_) => _tryApplyConfig(),
            onSubmitted: _saveConnectionAddress,
            style: const TextStyle(color: AppColors.textPrimary, fontSize: 15),
            autocorrect: false,
            enableSuggestions: false,
            textCapitalization: TextCapitalization.none,
            decoration: const InputDecoration(
              hintText: 'host:port',
              hintStyle:
                  TextStyle(color: AppColors.textSecondary, fontSize: 15),
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              filled: false,
              isDense: true,
              contentPadding: EdgeInsets.zero,
            ),
          ),
        ),
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
            _ActionButton(
              icon: Icons.content_paste_outlined,
              label: 'Import',
              onPressed: (_isLoading || _preferredNodeId == null)
                  ? null
                  : _importPrivateKeyFromClipboard,
            ),
            _ActionButton(
              icon: Icons.upload_outlined,
              label: 'Export',
              onPressed:
                  (_isLoading || _privateKeyBytes == null) ? null : _showPrivateKeyExportSheet,
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


// ── OR divider ───────────────────────────────────────────────────────────────

class _OrDivider extends StatelessWidget {
  const _OrDivider();

  @override
  Widget build(BuildContext context) {
    return const Row(children: [
      Expanded(child: Divider(color: AppColors.border)),
      Padding(
        padding: EdgeInsets.symmetric(horizontal: 12),
        child: Text('or',
            style: TextStyle(fontSize: 13, color: AppColors.textSecondary)),
      ),
      Expanded(child: Divider(color: AppColors.border)),
    ]);
  }
}

// ── Sheet confirm button ──────────────────────────────────────────────────────

class _SheetBtn extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  final bool secondary;
  final bool danger;
  final IconData? icon;

  const _SheetBtn({
    required this.label,
    required this.onTap,
    this.secondary = false,
    this.danger = false,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final Color bg;
    final Color fg;
    if (danger) {
      bg = AppColors.statusRed;
      fg = Colors.white;
    } else if (secondary) {
      bg = AppColors.bgSurfaceActive;
      fg = AppColors.textPrimary;
    } else {
      bg = AppColors.accent;
      fg = Colors.black;
    }
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 48,
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(12),
        ),
        alignment: Alignment.center,
        child: icon != null
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 18, color: fg),
                  const SizedBox(width: 8),
                  Text(label,
                      style: TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w600, color: fg)),
                ],
              )
            : Text(
                label,
                style: TextStyle(
                    fontSize: 15, fontWeight: FontWeight.w600, color: fg),
              ),
      ),
    );
  }
}

// ── Styled input matching contacts_screen style ───────────────────────────────

class _StyledField extends StatelessWidget {
  final TextEditingController controller;
  final IconData icon;
  final String hint;
  final TextInputType? keyboardType;
  final bool monospace;
  final String? error;
  final ValueChanged<String>? onChanged;

  const _StyledField({
    required this.controller,
    required this.icon,
    required this.hint,
    this.keyboardType,
    this.monospace = false,
    this.error,
    this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          decoration: BoxDecoration(
            color: AppColors.bgSurfaceActive,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
                color: error != null ? AppColors.statusRed : AppColors.border),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Icon(icon, size: 22, color: AppColors.textSecondary),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: controller,
                  keyboardType: keyboardType,
                  onChanged: onChanged,
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 15,
                    fontFamily: monospace ? 'monospace' : null,
                  ),
                  decoration: InputDecoration(
                    hintText: hint,
                    hintStyle: const TextStyle(
                        color: AppColors.textSecondary, fontSize: 15),
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    filled: false,
                    isDense: true,
                    contentPadding:
                        const EdgeInsets.symmetric(vertical: 14),
                  ),
                ),
              ),
            ],
          ),
        ),
        if (error != null) ...[
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.only(left: 4),
            child: Text(error!,
                style: const TextStyle(
                    fontSize: 12, color: AppColors.statusRed)),
          ),
        ],
      ],
    );
  }
}

// ── Account switcher widgets ──────────────────────────────────────────────────

/// Avatar that shows a profile image if available, otherwise a letter.
class _AccAvatarImage extends StatelessWidget {
  final Uint8List? avatar;
  final String name;
  const _AccAvatarImage({required this.avatar, required this.name});

  @override
  Widget build(BuildContext context) {
    final letter = name.isNotEmpty ? name[0].toUpperCase() : '?';
    return Container(
      width: 42,
      height: 42,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: AppColors.bgMain,
        border: const Border.fromBorderSide(BorderSide(color: AppColors.border)),
        image: avatar != null
            ? DecorationImage(image: MemoryImage(avatar!), fit: BoxFit.cover)
            : null,
      ),
      child: avatar == null
          ? Center(
              child: Text(
                letter,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary,
                ),
              ),
            )
          : null,
    );
  }
}

/// Avatar showing first letter of a node name (no image support).
class _AccAvatar extends StatelessWidget {
  final String name;
  const _AccAvatar({required this.name});

  @override
  Widget build(BuildContext context) {
    final letter = name.isNotEmpty ? name[0].toUpperCase() : '?';
    return Container(
      width: 42,
      height: 42,
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        color: AppColors.bgMain,
        border: Border.fromBorderSide(BorderSide(color: AppColors.border)),
      ),
      child: Center(
        child: Text(
          letter,
          style: const TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w600,
            color: AppColors.textPrimary,
          ),
        ),
      ),
    );
  }
}

class _AccountDropdownItem extends StatelessWidget {
  final NodeConfig node;
  final bool isActive;
  final Uint8List? profileAvatar;
  final String? profileName;
  final VoidCallback onTap;
  final VoidCallback onShare;
  final VoidCallback onDelete;

  const _AccountDropdownItem({
    required this.node,
    required this.isActive,
    this.profileAvatar,
    this.profileName,
    required this.onTap,
    required this.onShare,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final nick = (profileName ?? '').trim();
    final displayName = nick.isNotEmpty ? nick : node.name;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        color: isActive ? AppColors.bgMain : Colors.transparent,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        child: Row(
          children: [
            _AccAvatarImage(avatar: profileAvatar, name: displayName),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    displayName,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                      color: AppColors.textPrimary,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    node.chatAddress,
                    style: const TextStyle(
                        fontSize: 13, color: AppColors.textSecondary),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            // QR share
            GestureDetector(
              onTap: onShare,
              child: const SizedBox(
                width: 36,
                height: 36,
                child: Icon(Icons.qr_code_outlined,
                    size: 20, color: AppColors.textSecondary),
              ),
            ),
            const SizedBox(width: 4),
            // Active check OR delete
            if (isActive)
              const Icon(Icons.check_circle,
                  size: 20, color: Color(0xFF0A84FF))
            else
              GestureDetector(
                onTap: onDelete,
                child: const SizedBox(
                  width: 36,
                  height: 36,
                  child: Icon(Icons.delete_outline,
                      size: 20, color: AppColors.statusRed),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _AddAccountOption extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _AddAccountOption({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.bgSurfaceActive,
          border: Border.all(color: AppColors.border),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: AppColors.bgMain,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: AppColors.textPrimary, size: 24),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: const TextStyle(
                        fontSize: 13, color: AppColors.textSecondary),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────

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
