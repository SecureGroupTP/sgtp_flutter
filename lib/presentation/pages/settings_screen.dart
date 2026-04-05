import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:camera/camera.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:cryptography/cryptography.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
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
import '../widgets/styled_dropdown.dart';
import '../widgets/user_avatar.dart';
import 'logs_screen.dart';
import 'package:url_launcher/url_launcher.dart';

typedef ConfigChangedCallback = void Function(
    String accountId,
    SgtpConfig config,
    Map<String, String> nicknames,
    String serverAddress,
    List<WhitelistEntry> whitelistEntries);

enum _SettingsSection {
  key,
  chats,
  system,
  data,
  help,
}

typedef UserAvatarChangedCallback = void Function(Uint8List? avatar);

class SettingsScreen extends StatefulWidget {
  final SgtpConfig? initialConfig;
  final Map<String, String>? initialNicknames;
  final ConfigChangedCallback? onConfigChanged;
  final UserAvatarChangedCallback? onUserAvatarChanged;
  final Uint8List? currentUserAvatar;
  final void Function(String nickname)? onNicknameChanged;
  final Future<String?> Function(String username)? onUsernameChanged;
  final VoidCallback? onAllDataDeleted;

  const SettingsScreen({
    super.key,
    this.initialConfig,
    this.initialNicknames,
    this.onConfigChanged,
    this.onUserAvatarChanged,
    this.currentUserAvatar,
    this.onNicknameChanged,
    this.onUsernameChanged,
    this.onAllDataDeleted,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _settings = SettingsRepository();
  final _logsCountNotifier = _LogsCountNotifier();
  final _nicknameCtrl = TextEditingController();
  final _usernameCtrl = TextEditingController();
  String _standaloneServerAddress = '';

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
  String? _usernameError;

  /// Ping interval in seconds. Saved via SettingsRepository.
  int _pingIntervalSeconds = 30;
  bool _compressFiles = false;
  bool _compressPhotos = false;
  bool _compressVideos = false;
  int _mediaChunkSizeBytes = SgtpConstants.defaultMediaChunkSize;
  bool _captureDevicesLoading = false;
  List<InputDevice> _microphones = const [];
  String? _selectedMicrophoneId;
  List<CameraDescription> _cameras = const [];
  String? _selectedCameraName;
  final AudioRecorder _micCheckRecorder = AudioRecorder();
  final AudioPlayer _micCheckPlayer = AudioPlayer();
  Timer? _micCheckTimer;
  bool _micCheckEnabled = false;
  bool _micCheckInFlight = false;
  CameraController? _cameraCheckController;
  bool _cameraCheckEnabled = false;
  bool _cameraCheckLoading = false;
  String? _cameraCheckError;
  int _cameraCheckToken = 0;

  // Interaction preferences (Fix 7)
  String _doubleTapDesktop = 'react'; // 'react' | 'reply'
  bool _swipeToReply = true;
  bool _longPressMenu = true;

  // Accounts (formerly Nodes)
  List<NodeConfig> _nodes = const [];
  List<String> _accountIdsList = const [];
  bool _nodesLoading = true;
  bool _accountsExpanded = false;
  _SettingsSection? _activeSection;
  bool _serversExpanded = false;
  String? _preferredNodeId;
  String? _preferredAccountId;

  @override
  void initState() {
    super.initState();
    _userAvatar = widget.currentUserAvatar;
    _loadFromConfig();
  }

  void _loadFromConfig() {
    final cfg = widget.initialConfig;
    if (cfg != null) {
      _standaloneServerAddress = cfg.serverAddr.trim();
      _myPublicKey = cfg.myPublicKey;
    }
    _nicknames = Map.from(widget.initialNicknames ?? {});
    _loadFromDisk();
  }

  Future<void> _loadFromDisk() async {
    // Load nodes first so we know which account is active.
    final nodes = await _settings.loadNodes();
    final accountIds = await _settings.loadAccountIds();
    unawaited(_logCachedDiscovery(nodes));
    for (final node in nodes) {
      unawaited(_runDiscoveryForNode(node));
    }
    final preferredNode = await _settings.loadPreferredNode();
    final preferredId =
        preferredNode?.id ?? (nodes.isNotEmpty ? nodes.first.id : null);
    final savedAccountId = await _settings.loadLastAccountId();
    final preferredAccountId =
        (savedAccountId != null && accountIds.contains(savedAccountId))
            ? savedAccountId
            : (accountIds.isNotEmpty ? accountIds.first : null);

    if (preferredAccountId != null && preferredAccountId.trim().isNotEmpty) {
      await _settings
          .migrateLegacyAccountDataToNodeIfNeeded(preferredAccountId);
    }

    if (mounted) {
      setState(() {
        _nodes = nodes;
        _accountIdsList = accountIds;
        _nodesLoading = false;
        _preferredNodeId = preferredId;
        _preferredAccountId = preferredAccountId;
      });
    }

    // Load account-scoped identity/profile/contacts for the active account.
    if (preferredAccountId != null && preferredAccountId.trim().isNotEmpty) {
      await _loadAccountData(preferredAccountId, applyConfig: false);
    } else {
      await _setMicrophoneCheckEnabled(false);
      await _setCameraCheckEnabled(false);
      final lastAddr = await _settings.getLastAddress();
      if (lastAddr != null && _standaloneServerAddress.isEmpty) {
        setState(() => _standaloneServerAddress = lastAddr.trim());
      }
      if (mounted) {
        setState(() {
          _microphones = const [];
          _selectedMicrophoneId = null;
          _cameras = const [];
          _selectedCameraName = null;
        });
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

    unawaited(_refreshProfilesCache(accountIds));
  }

  @override
  void dispose() {
    _micCheckTimer?.cancel();
    unawaited(_micCheckRecorder.stop());
    unawaited(_micCheckRecorder.dispose());
    unawaited(_micCheckPlayer.stop());
    unawaited(_micCheckPlayer.dispose());
    final cameraController = _cameraCheckController;
    _cameraCheckController = null;
    if (cameraController != null) {
      unawaited(cameraController.dispose());
    }
    _nicknameCtrl.dispose();
    _usernameCtrl.dispose();
    _logsCountNotifier.dispose();
    super.dispose();
  }

  Map<String, String> _buildNicknames(List<WhitelistEntry> entries) {
    final result = <String, String>{};
    for (final e in entries) {
      result[e.hexKey] = e.name;
    }
    return result;
  }

  Future<void> _loadAccountData(String accountId,
      {bool applyConfig = true}) async {
    // Profile (nickname + username + avatar)
    final nickname = await _settings.loadUserNicknameForNode(accountId);
    final username = await _settings.loadUserUsernameForNode(accountId);
    final avatar = await _settings.loadUserAvatarForNode(accountId);

    // Identity key
    Uint8List? privBytes;
    String? privName;
    Uint8List? pubKey;
    final savedKey = await _settings.loadPrivateKeyForNode(accountId);
    if (savedKey != null) {
      try {
        final parsed = parseOpenSshPrivateKey(savedKey.bytes);
        privBytes = savedKey.bytes;
        privName = savedKey.name;
        pubKey = parsed.publicKey;
      } catch (_) {}
    }

    // Contacts (whitelist)
    final entries = await _settings.loadWhitelistEntriesForNode(accountId);

    if (!mounted) return;
    setState(() {
      _nickname = nickname;
      _nicknameCtrl.text = nickname;
      _usernameCtrl.text = username;
      _usernameError = null;
      _userAvatar = avatar;
      _avatarsByNodeId[accountId] = avatar;
      _nicknamesByNodeId[accountId] = nickname;

      _privateKeyBytes = privBytes;
      _privateKeyPath = privName;
      _myPublicKey = pubKey;

      _wlEntries = entries;
      _nicknames = _buildNicknames(entries);
    });
    await _loadCaptureDevicesForAccount(accountId);

    widget.onUserAvatarChanged?.call(avatar);
    if (applyConfig) _tryApplyConfig();
  }

  Future<void> _refreshProfilesCache(List<String> accountIds) async {
    final nextAvatars = <String, Uint8List?>{};
    final nextNicks = <String, String>{};
    for (final accountId in accountIds) {
      nextAvatars[accountId] = await _settings.loadUserAvatarForNode(accountId);
      nextNicks[accountId] = await _settings.loadUserNicknameForNode(accountId);
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

  Future<void> _loadCaptureDevicesForAccount(String accountId) async {
    if (accountId.trim().isEmpty) return;
    await _setMicrophoneCheckEnabled(false);
    await _setCameraCheckEnabled(false);
    if (mounted) setState(() => _captureDevicesLoading = true);

    List<InputDevice> microphones = const [];
    List<CameraDescription> cameras = const [];
    try {
      microphones = await AudioRecorder().listInputDevices();
    } catch (_) {}
    try {
      cameras = await availableCameras();
    } catch (_) {}

    final savedMicId =
        await _settings.loadPreferredMicrophoneForNode(accountId);
    final savedCameraName =
        await _settings.loadPreferredCameraForNode(accountId);

    String? selectedMicId;
    for (final mic in microphones) {
      if (mic.id == savedMicId) {
        selectedMicId = mic.id;
        break;
      }
    }
    selectedMicId ??= microphones.isNotEmpty ? microphones.first.id : null;

    String? selectedCameraName;
    for (final cam in cameras) {
      if (cam.name == savedCameraName) {
        selectedCameraName = cam.name;
        break;
      }
    }
    selectedCameraName ??= cameras.isNotEmpty ? cameras.first.name : null;

    if (!mounted) return;
    setState(() {
      _microphones = microphones;
      _selectedMicrophoneId = selectedMicId;
      _cameras = cameras;
      _selectedCameraName = selectedCameraName;
      _captureDevicesLoading = false;
      _cameraCheckError = null;
    });
  }

  String _cameraLabel(CameraDescription cam) {
    return switch (cam.lensDirection) {
      CameraLensDirection.front => 'Front camera',
      CameraLensDirection.back => 'Back camera',
      CameraLensDirection.external => 'External camera',
    };
  }

  Future<void> _selectMicrophone(String id) async {
    final accountId = _activeAccountId();
    if (accountId == null) return;
    await _settings.savePreferredMicrophoneForNode(accountId, id);
    if (!mounted) return;
    setState(() => _selectedMicrophoneId = id);
    if (_micCheckEnabled) {
      await _setMicrophoneCheckEnabled(true, restart: true);
    }
  }

  Future<void> _selectCamera(String name) async {
    final accountId = _activeAccountId();
    if (accountId == null) return;
    await _settings.savePreferredCameraForNode(accountId, name);
    if (!mounted) return;
    setState(() => _selectedCameraName = name);
    if (_cameraCheckEnabled) {
      await _setCameraCheckEnabled(true, restart: true);
    }
  }

  Future<void> _setMicrophoneCheckEnabled(bool enabled,
      {bool restart = false}) async {
    if (enabled && _micCheckEnabled && !restart) return;
    if (!enabled && !_micCheckEnabled && !restart) return;

    _micCheckTimer?.cancel();
    _micCheckTimer = null;
    _micCheckEnabled = false;
    _micCheckInFlight = false;
    try {
      await _micCheckRecorder.stop();
    } catch (_) {}
    try {
      await _micCheckPlayer.stop();
    } catch (_) {}

    if (!enabled) {
      if (mounted) setState(() {});
      return;
    }

    final selectedId = _selectedMicrophoneId;
    if (selectedId == null || selectedId.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Select a microphone first')),
        );
        setState(() {});
      }
      return;
    }

    InputDevice? input;
    for (final mic in _microphones) {
      if (mic.id == selectedId) {
        input = mic;
        break;
      }
    }
    if (input == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Selected microphone is unavailable')),
        );
      }
      return;
    }

    final hasPermission = await _micCheckRecorder.hasPermission();
    if (!hasPermission) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Microphone permission is missing')),
        );
      }
      return;
    }

    _micCheckEnabled = true;
    if (mounted) {
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Microphone check enabled')),
      );
    }

    Future<void> runCycle() async {
      if (!_micCheckEnabled || _micCheckInFlight) return;
      _micCheckInFlight = true;
      String? path;
      try {
        final dir = await getTemporaryDirectory();
        path =
            '${dir.path}/mic_loop_${DateTime.now().millisecondsSinceEpoch}.m4a';
        await _micCheckRecorder.start(
          RecordConfig(
            encoder: AudioEncoder.aacLc,
            bitRate: 128000,
            sampleRate: 44100,
            device: input,
          ),
          path: path,
        );
        await Future.delayed(const Duration(milliseconds: 900));
        final recordedPath = await _micCheckRecorder.stop() ?? path;
        final bytes = await File(recordedPath).readAsBytes();
        if (bytes.isNotEmpty && _micCheckEnabled) {
          await _micCheckPlayer.stop();
          await _micCheckPlayer.play(BytesSource(bytes));
        }
      } catch (_) {
        await _setMicrophoneCheckEnabled(false);
      } finally {
        if (path != null) {
          try {
            await File(path).delete();
          } catch (_) {}
        }
        _micCheckInFlight = false;
      }
    }

    unawaited(runCycle());
    _micCheckTimer = Timer.periodic(const Duration(milliseconds: 1300), (_) {
      unawaited(runCycle());
    });
  }

  Future<void> _setCameraCheckEnabled(bool enabled,
      {bool restart = false}) async {
    if (enabled && _cameraCheckEnabled && !restart) return;
    if (!enabled && !_cameraCheckEnabled && !restart) return;

    _cameraCheckEnabled = false;
    _cameraCheckLoading = false;
    _cameraCheckError = null;
    final previousController = _cameraCheckController;
    _cameraCheckController = null;
    if (previousController != null) {
      await previousController.dispose();
    }

    if (!enabled) {
      if (mounted) setState(() {});
      return;
    }

    final selectedName = _selectedCameraName;
    if (selectedName == null || selectedName.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Select a camera first')),
        );
      }
      return;
    }
    CameraDescription? selectedCamera;
    for (final cam in _cameras) {
      if (cam.name == selectedName) {
        selectedCamera = cam;
        break;
      }
    }
    if (selectedCamera == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Selected camera is unavailable')),
        );
      }
      return;
    }

    _cameraCheckEnabled = true;
    _cameraCheckLoading = true;
    _cameraCheckError = null;
    if (mounted) {
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Camera check enabled')),
      );
    }

    final token = ++_cameraCheckToken;
    try {
      final controller = CameraController(
        selectedCamera,
        ResolutionPreset.medium,
        enableAudio: false,
      );
      await controller.initialize();
      if (!mounted || token != _cameraCheckToken || !_cameraCheckEnabled) {
        await controller.dispose();
        return;
      }
      setState(() {
        _cameraCheckController = controller;
        _cameraCheckLoading = false;
      });
    } catch (e) {
      if (!mounted || token != _cameraCheckToken) return;
      setState(() {
        _cameraCheckEnabled = false;
        _cameraCheckLoading = false;
        _cameraCheckError = 'Failed to initialize camera: $e';
      });
    }
  }

  // ── Private key: browse ──────────────────────────────────────────────────

  Future<void> _pickPrivateKey() async {
    final accountId = _activeAccountId();
    if (accountId == null) return;
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
      await _settings.savePrivateKeyForNode(accountId, bytes, file.name);
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
                    icon:
                        const Icon(Icons.close, color: AppColors.textSecondary),
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
                    foregroundColor: const WidgetStatePropertyAll(Colors.black),
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
    final accountId = _activeAccountId();
    if (accountId == null) return;

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
      await _settings.savePrivateKeyForNode(
          accountId, bytes, 'clipboard_identity');
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

  Future<bool> _pickPrivateKeyForAccount(String accountId) async {
    try {
      final result = await FilePicker.platform
          .pickFiles(type: FileType.any, withData: true, allowMultiple: false);
      if (result == null || result.files.isEmpty) return false;
      final file = result.files.first;
      final bytes = file.bytes;
      if (bytes == null) return false;
      // Validate
      parseOpenSshPrivateKey(bytes);
      await _settings.savePrivateKeyForNode(accountId, bytes, file.name);
      return true;
    } catch (_) {
      return false;
    }
  }

  // ── Private key: generate ────────────────────────────────────────────────

  Future<void> _generatePrivateKey() async {
    final accountId = _activeAccountId();
    if (accountId == null) return;
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
      await _settings.savePrivateKeyForNode(accountId, opensshBytes, name);

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

  Future<bool> _generatePrivateKeyForAccount(String accountId) async {
    try {
      final algorithm = Ed25519();
      final keyPair = await algorithm.newKeyPair();
      final pubKey = await keyPair.extractPublicKey();
      final privBytes = await keyPair.extractPrivateKeyBytes();
      final pubBytes = Uint8List.fromList(pubKey.bytes);
      final opensshBytes = _encodeOpenSshPrivateKey(privBytes, pubBytes);
      await _settings.savePrivateKeyForNode(
          accountId, opensshBytes, 'identity');
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _pastePrivateKeyForAccount(String accountId, String text) async {
    try {
      final bytes = Uint8List.fromList(text.codeUnits);
      // Validate
      parseOpenSshPrivateKey(bytes);
      await _settings.savePrivateKeyForNode(
          accountId, bytes, 'pasted_identity');
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _promptPrivateKeyForAccount(String accountId) async {
    final existing = await _settings.loadPrivateKeyForNode(accountId);
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
                      final ok = await _pickPrivateKeyForAccount(accountId);
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
                      final ok = await _generatePrivateKeyForAccount(accountId);
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
                        hintText: '-----BEGIN OPENSSH PRIVATE KEY-----\n…',
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
                          await _pastePrivateKeyForAccount(accountId, text);
                      if (!ctx.mounted) return;
                      if (ok) {
                        saved = true;
                        Navigator.pop(ctx);
                      } else {
                        setS(() =>
                            error = 'Invalid private key (OpenSSH format)');
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
      final accountId = _activeAccountId();
      if (accountId == null) return;
      await _settings.saveWhitelistEntriesForNode(accountId, entries);
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
      final accountId = _activeAccountId();
      if (accountId == null) return;
      await _settings.saveWhitelistEntriesForNode(accountId, combined);
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
    final accountId = _activeAccountId();
    if (accountId == null) return;
    await _settings.saveWhitelistEntriesForNode(accountId, combined);
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
    final accountId = _activeAccountId();
    if (accountId == null) return;
    await _settings.saveWhitelistEntriesForNode(accountId, updated);
    setState(() {
      _wlEntries = updated;
      _nicknames = _buildNicknames(updated);
    });
    _tryApplyConfig();
  }

  // ── Whitelist: remove ─────────────────────────────────────────────────────

  Future<void> _removeEntry(int index) async {
    final newList = List<WhitelistEntry>.from(_wlEntries)..removeAt(index);
    final accountId = _activeAccountId();
    if (accountId == null) return;
    await _settings.saveWhitelistEntriesForNode(accountId, newList);
    setState(() {
      _wlEntries = newList;
      _nicknames = _buildNicknames(newList);
    });
    _tryApplyConfig();
  }

  // ── User avatar ───────────────────────────────────────────────────────────

  Future<void> _pickUserAvatar() async {
    final accountId = _activeAccountId();
    if (accountId == null) return;
    Uint8List? bytes;

    final picker = ImagePicker();
    final file = await picker.pickImage(
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
    await _settings.saveUserAvatarForNode(accountId, bytes);
    setState(() {
      _userAvatar = bytes;
      _error = null;
    });
    widget.onUserAvatarChanged?.call(bytes);
    _avatarsByNodeId[accountId] = bytes;
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Avatar saved')),
      );
    }
  }

  Future<void> _removeUserAvatar() async {
    final accountId = _activeAccountId();
    if (accountId == null) return;
    await _settings.clearUserAvatarForNode(accountId);
    setState(() => _userAvatar = null);
    widget.onUserAvatarChanged?.call(null);
    _avatarsByNodeId[accountId] = null;
  }

  // ── Config apply ──────────────────────────────────────────────────────────

  void _tryApplyConfig() {
    if (_privateKeyBytes == null || _myPublicKey == null) return;
    final server = _effectiveServerAddress();
    try {
      final parsed = parseOpenSshPrivateKey(_privateKeyBytes!);
      final keyPair = makeKeyPair(parsed.seed, parsed.publicKey);
      final whitelist = _wlEntries.map((e) => e.hexKey).toSet();
      final node = _selectedServerNode();
      if (node == null) return;
      final accountId = _activeAccountId();
      if (accountId == null) return;
      if (accountId.trim().isEmpty) return;
      final newConfig = SgtpConfig(
        accountId: accountId,
        serverAddr: server,
        roomUUID: Uint8List(16),
        identityKeyPair: keyPair,
        myPublicKey: parsed.publicKey,
        whitelist: whitelist,
        transport: node.transport,
        useTls: node.useTls,
        nodeId: node.id,
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

  NodeConfig? _activeNode() {
    if (_preferredNodeId != null) {
      for (final node in _nodes) {
        if (node.id == _preferredNodeId) return node;
      }
    }
    if (_nodes.isNotEmpty) return _nodes.first;
    return null;
  }

  List<String> _accountIds() {
    return List<String>.from(_accountIdsList);
  }

  NodeConfig? _representativeNodeForAccount(String accountId) {
    final id = accountId.trim();
    if (id.isEmpty) return null;
    for (final n in _nodes) {
      if (n.effectiveAccountId == id) return n;
    }
    return null;
  }

  String _accountName(String accountId) {
    final rep = _representativeNodeForAccount(accountId);
    final nick = (_nicknamesByNodeId[accountId] ?? '').trim();
    if (nick.isNotEmpty) return nick;
    if (rep != null) return rep.name;
    if (accountId.length >= 8) return 'Account ${accountId.substring(0, 8)}';
    return 'Account';
  }

  Uint8List? _accountAvatar(String accountId) {
    return _avatarsByNodeId[accountId];
  }

  String? _activeAccountId() {
    final id = (_preferredAccountId ?? '').trim();
    return id.isEmpty ? null : id;
  }

  Future<void> _selectServer(NodeConfig node) async {
    setState(() {
      _preferredNodeId = node.id;
      _serversExpanded = false;
    });
    await _settings.setLastNodeId(node.id);
    _tryApplyConfig();
  }

  Future<void> _selectAccountId(String accountId) async {
    final id = accountId.trim();
    if (id.isEmpty) return;
    setState(() {
      _preferredAccountId = id;
      _accountsExpanded = false;
    });
    await _settings.setLastAccountId(id);
    await _loadAccountData(id, applyConfig: true);
  }

  Future<void> _deleteAccount(String accountId) async {
    final id = accountId.trim();
    if (id.isEmpty) return;
    final linkedServers =
        _nodes.where((n) => n.accountId.trim() == id).toList();
    final label = _accountName(id);
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text('Delete Account?'),
            content: Text('Delete "$label"? '
                'Linked servers (${linkedServers.length}) will be kept and detached from this account. '
                'Profile/key data for this account will no longer be used.'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.statusRed,
                ),
                child: const Text('Delete'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed) return;
    for (final n in linkedServers) {
      await _settings.upsertNode(n.copyWith(accountId: ''));
    }
    await _settings.clearPrivateKeyForNode(id);
    await _settings.clearWhitelistForNode(id);
    await _settings.clearUserAvatarForNode(id);
    await _settings.saveUserNicknameForNode(id, '');
    await _settings.saveUserUsernameForNode(id, '');
    await _settings.deleteAccountId(id);
    await _reloadNodes();
    final nextAccount = _activeAccountId();
    if (nextAccount != null) {
      await _loadAccountData(nextAccount, applyConfig: true);
    }
  }

  Future<void> _deleteServer(NodeConfig node) async {
    await _deleteNode(node);
  }

  NodeConfig? _selectedServerNode() {
    if (_preferredNodeId != null) {
      for (final n in _nodes) {
        if (n.id == _preferredNodeId) return n;
      }
    }
    return _nodes.isNotEmpty ? _nodes.first : null;
  }

  String _selectedServerLabel() {
    final node = _selectedServerNode();
    if (node == null) return 'No servers';
    return '${node.name} (${node.chatAddress})';
  }

  String? _selectedServerId() {
    final node = _selectedServerNode();
    if (node == null) return null;
    final id = node.id.trim();
    return id.isEmpty ? null : id;
  }

  String _effectiveServerAddress() {
    final active = _selectedServerNode();
    if (active != null) return active.chatAddress;
    final normalized = _standaloneServerAddress
        .trim()
        .replaceAll(RegExp(r'^https?://', caseSensitive: false), '')
        .replaceAll(RegExp(r'^wss?://', caseSensitive: false), '')
        .trim();
    return normalized.isEmpty ? 'localhost:443' : normalized;
  }

  // ── Nodes ────────────────────────────────────────────────────────────────

  Future<void> _runDiscoveryForNode(NodeConfig node) async {
    try {
      final (:opts, :port, :tls) =
          await SgtpServerDiscovery.discover(node.host);
      await _settings.saveNodeServerOptions(node.id, opts);
      final labels = [
        if (opts.tcp) 'TCP:${opts.tcpPort}',
        if (opts.tcpTls) 'TCP+TLS:${opts.tcpTlsPort}',
        if (opts.http) 'HTTP:${opts.httpPort}',
        if (opts.httpTls) 'HTTP+TLS:${opts.httpTlsPort}',
        if (opts.websocket) 'WebSocket:${opts.websocketPort}',
        if (opts.websocketTls) 'WebSocket+TLS:${opts.websocketTlsPort}',
      ];
      AppLogger.i(
          'Discovery [${node.name}] ${node.host} via '
          '${tls ? 'https' : 'http'}:$port: ${labels.join(", ")}',
          tag: 'DISC');
    } catch (e) {
      AppLogger.w('Discovery [${node.name}] ${node.host}: failed — $e',
          tag: 'DISC');
    }
  }

  Future<void> _logCachedDiscovery(List<NodeConfig> nodes) async {
    if (nodes.isEmpty) {
      AppLogger.i('Discovery cache: no accounts configured', tag: 'DISC');
      return;
    }
    for (final node in nodes) {
      final opts = await _settings.loadNodeServerOptions(node.id);
      final at = await _settings.loadNodeServerOptionsSavedAt(node.id);
      if (opts == null) {
        AppLogger.i(
            'Discovery cache [${node.name}] ${node.chatAddress}: no cache',
            tag: 'DISC');
      } else {
        final age = at != null
            ? '${DateTime.now().difference(at).inMinutes}m ago'
            : 'unknown age';
        final labels = [
          if (opts.tcp) 'TCP:${opts.tcpPort}',
          if (opts.tcpTls) 'TCP+TLS:${opts.tcpTlsPort}',
          if (opts.http) 'HTTP:${opts.httpPort}',
          if (opts.httpTls) 'HTTP+TLS:${opts.httpTlsPort}',
          if (opts.websocket) 'WebSocket:${opts.websocketPort}',
          if (opts.websocketTls) 'WebSocket+TLS:${opts.websocketTlsPort}',
        ];
        AppLogger.i(
            'Discovery cache [${node.name}] ${node.chatAddress}: '
            '${labels.join(", ")} ($age)',
            tag: 'DISC');
      }
    }
  }

  Future<void> _reloadNodes() async {
    final nodes = await _settings.loadNodes();
    final accountIds = await _settings.loadAccountIds();
    final preferred = await _settings.loadPreferredNode();
    final savedAccountId = await _settings.loadLastAccountId();
    final nextAccountId =
        (savedAccountId != null && accountIds.contains(savedAccountId))
            ? savedAccountId
            : (accountIds.isNotEmpty ? accountIds.first : null);
    if (!mounted) return;
    setState(() {
      _nodes = nodes;
      _accountIdsList = accountIds;
      _nodesLoading = false;
      _preferredNodeId =
          preferred?.id ?? (nodes.isNotEmpty ? nodes.first.id : null);
      _preferredAccountId = nextAccountId;
    });
    unawaited(_refreshProfilesCache(accountIds));
  }

  Future<NodeConfig?> _openNodeEditor(
      {NodeConfig? existing, String? accountIdForNew}) async {
    final baseId = existing?.id ?? uuidBytesToHex(generateUUIDv7());
    NodeConfig? result;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.bgSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => _NodeEditorSheet(
        existing: existing,
        baseId: baseId,
        accountIdForNew: accountIdForNew,
        settings: _settings,
        onSave: (node) {
          result = node;
          Navigator.of(ctx).pop();
        },
      ),
    );
    return result;
  }

  Future<void> _addServerOnly() async {
    final node = await _openNodeEditor();
    if (node == null) return;
    await _settings.upsertNode(node.copyWith(accountId: ''));
    unawaited(_runDiscoveryForNode(node));
    await _reloadNodes();
    _tryApplyConfig();
  }

  Future<void> _addAccountOnly() async {
    final accountId = uuidBytesToHex(generateUUIDv7());
    await _settings.upsertAccountId(accountId);
    await _settings.saveUserNicknameForNode(accountId, 'Account');
    await _settings.setLastAccountId(accountId);
    await _reloadNodes();
    if (!mounted) return;
    final ok = await _promptPrivateKeyForAccount(accountId);
    if (!mounted) return;
    await _selectAccountId(accountId);
    if (!mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Account added without private key')),
      );
    }
  }

  Future<void> _editNode(NodeConfig node) async {
    final updated = await _openNodeEditor(existing: node);
    if (updated == null) return;
    await _settings.upsertNode(updated.copyWith(accountId: ''));
    unawaited(_runDiscoveryForNode(updated));
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
                'Delete Server?',
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
                    TextSpan(text: ' (${node.chatAddress}) from your servers?'),
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
    final activeSection = _activeSection;
    return Scaffold(
      backgroundColor: AppColors.bgMain,
      appBar: activeSection == null
          ? const _SettingsAppBar()
          : _InlineSubSettingsAppBar(
              title: _sectionTitle(activeSection),
              onBack: () => setState(() => _activeSection = null),
            ),
      body: ListView(
        padding: EdgeInsets.only(top: activeSection == null ? 0 : 20, bottom: 100),
        children: activeSection == null
            ? [
                _buildAccountSwitcher(),
                _buildProfileSection(),
                _SettingsGroup(title: 'Server Connection', child: _buildNetworkCard()),
                _buildSettingsHub(),
                const SizedBox(height: 16),
              ]
            : [
                ..._sectionChildren(activeSection),
                const SizedBox(height: 16),
              ],
      ),
    );
  }

  Widget _buildSettingsHub() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
          child: Text(
            'PREFERENCES',
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: AppColors.textSecondary,
              letterSpacing: 1,
            ),
          ),
        ),
        Container(
          decoration: const BoxDecoration(
            color: AppColors.bgSurface,
            border: Border(
              top: BorderSide(color: AppColors.border),
              bottom: BorderSide(color: AppColors.border),
            ),
          ),
          child: Column(
            children: [
              _SettingsNavTile(
                icon: Icons.vpn_key_outlined,
                iconBgColor: const Color(0xFF004a99),
                title: 'Key Settings',
                onTap: () =>
                    setState(() => _activeSection = _SettingsSection.key),
              ),
              const Divider(height: 1, indent: 70, color: AppColors.border),
              _SettingsNavTile(
                icon: Icons.chat_bubble_outline,
                iconBgColor: const Color(0xFF1a7431),
                title: 'Chats & Media',
                onTap: () =>
                    setState(() => _activeSection = _SettingsSection.chats),
              ),
              const Divider(height: 1, indent: 70, color: AppColors.border),
              _SettingsNavTile(
                icon: Icons.storage_outlined,
                iconBgColor: const Color(0xFF995a00),
                title: 'Media Caching',
                onTap: () =>
                    setState(() => _activeSection = _SettingsSection.data),
              ),
              const Divider(height: 1, indent: 70, color: AppColors.border),
              _SettingsNavTile(
                icon: Icons.terminal_outlined,
                iconBgColor: const Color(0xFF6a308a),
                title: 'Logs & Debug',
                onTap: () =>
                    setState(() => _activeSection = _SettingsSection.system),
              ),
              const Divider(height: 1, indent: 70, color: AppColors.border),
              _SettingsNavTile(
                icon: Icons.info_outline,
                iconBgColor: const Color(0xFF4a4a4f),
                title: 'App Information',
                onTap: () =>
                    setState(() => _activeSection = _SettingsSection.help),
              ),
            ],
          ),
        ),
      ],
    );
  }

  String _sectionTitle(_SettingsSection section) => switch (section) {
        _SettingsSection.key => 'Key Settings',
        _SettingsSection.chats => 'Chats & Media',
        _SettingsSection.system => 'Logs & Debug',
        _SettingsSection.data => 'Media Caching',
        _SettingsSection.help => 'App Information',
      };

  List<Widget> _sectionChildren(_SettingsSection section) => switch (section) {
        _SettingsSection.key => [
            _SettingsGroup(
              title: 'Private Key (Ed25519)',
              child: _buildPrivateKeyCard(),
            ),
          ],
        _SettingsSection.chats => [
            _SettingsGroup(title: 'Interaction', child: _buildInteractionCard()),
            _SettingsGroup(title: 'Media', child: _buildMediaCard()),
          ],
        _SettingsSection.system => [
            _SettingsGroup(title: 'Logs', child: _buildLogsCard()),
          ],
        _SettingsSection.data => [
            _SettingsGroup(title: 'Data', child: _buildDataCard()),
          ],
        _SettingsSection.help => [
            _SettingsGroup(title: 'About', child: _buildAboutCard()),
            _buildGettingStarted(),
          ],
      };

  // ── Profile section ───────────────────────────────────────────────────────

  Future<void> _saveNickname(String value) async {
    final accountId = _activeAccountId();
    if (accountId == null) return;
    final next = value.trim();
    await _settings.saveUserNicknameForNode(accountId, next);
    if (!mounted) return;
    setState(() => _nickname = next);
    _nicknamesByNodeId[accountId] = next;
    widget.onNicknameChanged?.call(next);
  }

  Future<void> _saveUsername(String value) async {
    final accountId = _activeAccountId();
    if (accountId == null) return;
    // Strip leading @ if user typed it, sanitize
    final stripped = value.trim().replaceFirst(RegExp(r'^@'), '');
    final sanitized = stripped
        .replaceAll(RegExp(r'[^A-Za-z0-9_]'), '')
        .substring(
          0,
          stripped.replaceAll(RegExp(r'[^A-Za-z0-9_]'), '').length.clamp(0, 32),
        );
    await _settings.saveUserUsernameForNode(accountId, sanitized);
    if (!mounted) return;
    final remoteError = await widget.onUsernameChanged?.call(sanitized);
    if (!mounted) return;
    setState(() {
      _usernameError = remoteError;
    });
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
      nodeTransport: node.transport.id,
      nodeUseTls: node.useTls,
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
                          }
                          return;
                        }

                        final parsed = _parseHostPort(raw);
                        if (parsed == null) {
                          setS(() => errorMsg =
                              'Could not parse — paste node share hex/base64 or host:port');
                          return;
                        }

                        final (host, _) = parsed;
                        final node = NodeConfig(
                          id: uuidBytesToHex(generateUUIDv7()),
                          name: host,
                          host: host,
                          chatPort: 443,
                          voicePort: 443,
                        );
                        await _settings
                            .upsertNode(node.copyWith(accountId: ''));
                        await _reloadNodes();
                        if (!mounted) return;
                        if (ctx.mounted) Navigator.pop(ctx);
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                              content:
                                  Text('Node imported: ${node.chatAddress}')),
                        );
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
    await _settings.upsertNode(node.copyWith(accountId: ''));
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
    int? chatPort;

    if ((host == null || host.isEmpty) && data.serverAddress != null) {
      final parsed = _parseHostPort(data.serverAddress!);
      if (parsed != null) {
        host = parsed.$1;
        chatPort ??= parsed.$2;
      }
    }

    host = host?.trim();
    chatPort ??= 443;
    final voicePort = chatPort;

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
      transport: data.nodeTransportFamily ?? SgtpTransportFamily.tcp,
      useTls: data.nodeUseTls ?? false,
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
                UserAvatar(
                  name: _nickname.isNotEmpty ? _nickname : 'Me',
                  bytes: _userAvatar,
                  size: 88,
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
                borderSide: BorderSide(
                    color: _usernameError != null
                        ? AppColors.statusRed
                        : AppColors.border),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(
                    color: _usernameError != null
                        ? AppColors.statusRed
                        : AppColors.border),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(
                    color: _usernameError != null
                        ? AppColors.statusRed
                        : AppColors.textSecondary),
              ),
              contentPadding: const EdgeInsets.symmetric(vertical: 14),
            ),
          ),
          if (_usernameError != null) ...[
            const SizedBox(height: 6),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                _usernameError!,
                style:
                    const TextStyle(fontSize: 12, color: AppColors.statusRed),
              ),
            ),
          ],
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
    final accountIds = _accountIds();
    final activeAccountId = _activeAccountId();
    final hasAccounts = accountIds.isNotEmpty;
    final activeName =
        activeAccountId != null ? _accountName(activeAccountId) : 'No accounts';
    final activeAvatar =
        activeAccountId != null ? _accountAvatar(activeAccountId) : null;

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
                  UserAvatar(
                    bytes: _userAvatar ?? activeAvatar,
                    name: _nickname.isNotEmpty ? _nickname : activeName,
                    size: 42,
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
                                _nickname.isNotEmpty ? _nickname : activeName,
                                style: const TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                  color: AppColors.textPrimary,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
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
          if (!_nodesLoading && hasAccounts)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: Text(
                'Account: ${activeName}',
                style: const TextStyle(
                    fontSize: 13, color: AppColors.textSecondary),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          // ── Dropdown ───────────────────────────────────────────────────
          if (_accountsExpanded) ...[
            const Divider(height: 1, thickness: 1, color: AppColors.border),
            Column(
              children: [
                ...accountIds.map((id) {
                  final rep = _representativeNodeForAccount(id);
                  final displayNode = rep ??
                      NodeConfig(
                        id: id,
                        accountId: id,
                        name: _accountName(id),
                        host: '',
                        chatPort: 443,
                        voicePort: 443,
                      );
                  return _AccountDropdownItem(
                    node: displayNode,
                    isActive: id == activeAccountId,
                    profileAvatar: _accountAvatar(id),
                    profileName: _accountName(id),
                    onTap: () => unawaited(_selectAccountId(id)),
                    onShare: _showMyProfileShare,
                    onDelete: () => _deleteAccount(id),
                  );
                }),
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
                icon: Icons.person_add_alt_1_outlined,
                title: 'Create Account',
                subtitle: 'Create a new profile and set up its private key',
                onTap: () {
                  Navigator.pop(context);
                  _addAccountOnly();
                },
              ),
            ],
          ),
        ),
      ),
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
              onPressed: (_isLoading || _activeAccountId() == null)
                  ? null
                  : _importPrivateKeyFromClipboard,
            ),
            _ActionButton(
              icon: Icons.upload_outlined,
              label: 'Export',
              onPressed: (_isLoading || _privateKeyBytes == null)
                  ? null
                  : _showPrivateKeyExportSheet,
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
    final selectedServer = _selectedServerNode();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Server',
          style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
        ),
        const SizedBox(height: 8),
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => setState(() => _serversExpanded = !_serversExpanded),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: AppColors.bgMain,
              border: Border.all(color: AppColors.border),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                const Icon(Icons.dns_outlined,
                    size: 18, color: AppColors.textSecondary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    _selectedServerLabel(),
                    style: const TextStyle(
                      fontSize: 14,
                      color: AppColors.textPrimary,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                AnimatedRotation(
                  turns: _serversExpanded ? 0.5 : 0,
                  duration: const Duration(milliseconds: 220),
                  child: const Icon(Icons.expand_more,
                      color: AppColors.textSecondary),
                ),
              ],
            ),
          ),
        ),
        if (_serversExpanded) ...[
          const SizedBox(height: 8),
          Container(
            decoration: BoxDecoration(
              color: AppColors.bgMain,
              border: Border.all(color: AppColors.border),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              children: [
                ..._nodes.map((n) {
                  final isSelected = n.id == _selectedServerId();
                  return ListTile(
                    dense: true,
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
                    onTap: () => unawaited(_selectServer(n)),
                    leading: Icon(
                      isSelected
                          ? Icons.check_circle
                          : Icons.radio_button_unchecked,
                      color: isSelected
                          ? const Color(0xFF0A84FF)
                          : AppColors.textSecondary,
                      size: 18,
                    ),
                    title: Text(
                      n.name,
                      style: const TextStyle(
                        fontSize: 14,
                        color: AppColors.textPrimary,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      n.chatAddress,
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.textSecondary,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        GestureDetector(
                          onTap: () => _showNodeShare(n),
                          child: const SizedBox(
                            width: 28,
                            height: 28,
                            child: Icon(Icons.qr_code_outlined,
                                size: 18, color: AppColors.textSecondary),
                          ),
                        ),
                        const SizedBox(width: 6),
                        GestureDetector(
                          onTap: () => _editNode(n),
                          child: const SizedBox(
                            width: 28,
                            height: 28,
                            child: Icon(Icons.edit_outlined,
                                size: 18, color: AppColors.textSecondary),
                          ),
                        ),
                        const SizedBox(width: 6),
                        GestureDetector(
                          onTap: () => _deleteServer(n),
                          child: const SizedBox(
                            width: 28,
                            height: 28,
                            child: Icon(Icons.delete_outline,
                                size: 18, color: AppColors.statusRed),
                          ),
                        ),
                      ],
                    ),
                  );
                }),
                ListTile(
                  dense: true,
                  onTap: _addServerOnly,
                  leading:
                      const Icon(Icons.add, color: AppColors.textSecondary),
                  title: const Text(
                    'Add server',
                    style:
                        TextStyle(fontSize: 14, color: AppColors.textPrimary),
                  ),
                ),
              ],
            ),
          ),
        ],
        if (selectedServer != null) ...[
          const SizedBox(height: 10),
          Text(
            'Active: ${selectedServer.chatAddress} • ${selectedServer.transport.id.toUpperCase()}${selectedServer.useTls ? " +TLS" : ""}',
            style:
                const TextStyle(fontSize: 12, color: AppColors.textSecondary),
          ),
        ],
      ],
    );
  }

  Widget _buildCaptureDropdown({
    required String? value,
    required List<DropdownMenuItem<String>> items,
    required ValueChanged<String?> onChanged,
  }) {
    return Container(
      height: 48,
      decoration: BoxDecoration(
        color: const Color(0xFF1B1B1F),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: value,
          isExpanded: true,
          dropdownColor: AppColors.bgSurface,
          iconEnabledColor: AppColors.textSecondary,
          style: const TextStyle(color: AppColors.textPrimary),
          items: items,
          onChanged: onChanged,
        ),
      ),
    );
  }

  Widget _buildCameraCheckPreview() {
    final controller = _cameraCheckController;
    if (_cameraCheckLoading) {
      return const SizedBox(
        height: 128,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_cameraCheckError != null) {
      return Container(
        width: 156,
        height: 156,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: AppColors.bgMain,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.border),
        ),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Text(
            _cameraCheckError!,
            style: const TextStyle(color: AppColors.textSecondary, fontSize: 12),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    if (controller == null || !controller.value.isInitialized) {
      return const SizedBox.shrink();
    }
    return Align(
      alignment: Alignment.topLeft,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: SizedBox(
          width: 156,
          height: 156,
          child: FittedBox(
            fit: BoxFit.cover,
            child: SizedBox(
              width: 156,
              height: 156 / controller.value.aspectRatio,
              child: CameraPreview(controller),
            ),
          ),
        ),
      ),
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
        const SizedBox(height: 18),
        const Divider(color: AppColors.border),
        const SizedBox(height: 12),
        const Text(
          'Voice & Video Notes',
          style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
        ),
        const SizedBox(height: 10),
        if (_captureDevicesLoading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Row(
              children: [
                SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                SizedBox(width: 10),
                Text(
                  'Loading capture devices...',
                  style: TextStyle(color: AppColors.textSecondary),
                ),
              ],
            ),
          )
        else ...[
          const Text(
            'Microphone',
            style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
          ),
          const SizedBox(height: 6),
          if (_microphones.isEmpty)
            const Text(
              'No microphones found',
              style: TextStyle(color: AppColors.textSecondary),
            )
          else
            _buildCaptureDropdown(
              value: _selectedMicrophoneId,
              items: _microphones
                  .map(
                    (mic) => DropdownMenuItem<String>(
                      value: mic.id,
                      child: Text(mic.label),
                    ),
                  )
                  .toList(),
              onChanged: (id) {
                if (id == null) return;
                unawaited(_selectMicrophone(id));
              },
            ),
          const SizedBox(height: 8),
          SwitchListTile.adaptive(
            value: _micCheckEnabled,
            onChanged:
                _selectedMicrophoneId != null && _microphones.isNotEmpty
                    ? (v) => unawaited(_setMicrophoneCheckEnabled(v))
                    : null,
            dense: true,
            contentPadding: EdgeInsets.zero,
            activeThumbColor: AppColors.accent,
            activeTrackColor: AppColors.accent.withAlpha(110),
            title: const Text(
              'Microphone check',
              style: TextStyle(color: AppColors.textPrimary),
            ),
            subtitle: const Text(
              'Toggle on to hear your own voice',
              style: TextStyle(color: AppColors.textSecondary, fontSize: 12),
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Camera',
            style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
          ),
          const SizedBox(height: 6),
          if (_cameras.isEmpty)
            const Text(
              'No cameras found',
              style: TextStyle(color: AppColors.textSecondary),
            )
          else
            _buildCaptureDropdown(
              value: _selectedCameraName,
              items: _cameras
                  .map(
                    (cam) => DropdownMenuItem<String>(
                      value: cam.name,
                      child: Text('${_cameraLabel(cam)} (${cam.name})'),
                    ),
                  )
                  .toList(),
              onChanged: (name) {
                if (name == null) return;
                unawaited(_selectCamera(name));
              },
            ),
          const SizedBox(height: 8),
          SwitchListTile.adaptive(
            value: _cameraCheckEnabled,
            onChanged: _selectedCameraName != null && _cameras.isNotEmpty
                ? (v) => unawaited(_setCameraCheckEnabled(v))
                : null,
            dense: true,
            contentPadding: EdgeInsets.zero,
            activeThumbColor: AppColors.accent,
            activeTrackColor: AppColors.accent.withAlpha(110),
            title: const Text(
              'Camera check',
              style: TextStyle(color: AppColors.textPrimary),
            ),
            subtitle: const Text(
              'Toggle on to see live camera preview',
              style: TextStyle(color: AppColors.textSecondary, fontSize: 12),
            ),
          ),
          if (_cameraCheckEnabled || _cameraCheckLoading || _cameraCheckError != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: _buildCameraCheckPreview(),
            ),
        ],
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
        const SizedBox(height: 16),
        // ── Ping interval ───────────────────────────────────────────────
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
      listenable: _logsCountNotifier,
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

  Widget _buildDataCard() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Delete all local app data (accounts, servers, keys, chats, cached files).',
          style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
        ),
        const SizedBox(height: 12),
        _ActionButton(
          icon: Icons.delete_forever_outlined,
          label: 'Delete all my data',
          onPressed: _deleteAllMyData,
        ),
      ],
    );
  }

  Future<void> _deleteAllMyData() async {
    final code = (1000 + Random().nextInt(9000)).toString();
    final ctrl = TextEditingController();
    String? err;
    var confirmed = false;
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: const Text('Delete All Data?'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'This will permanently remove all local data from this device.',
              ),
              const SizedBox(height: 10),
              Text(
                'Type this code to confirm: $code',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: ctrl,
                keyboardType: TextInputType.number,
                autofocus: true,
                decoration: InputDecoration(
                  hintText: 'Enter code',
                  errorText: err,
                ),
                onChanged: (_) {
                  if (err != null) setS(() => err = null);
                },
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              style:
                  FilledButton.styleFrom(backgroundColor: AppColors.statusRed),
              onPressed: () {
                if (ctrl.text.trim() != code) {
                  setS(() => err = 'Code does not match');
                  return;
                }
                confirmed = true;
                Navigator.pop(ctx);
              },
              child: const Text('Delete'),
            ),
          ],
        ),
      ),
    );
    ctrl.dispose();
    if (!confirmed) return;

    try {
      await _settings.clearAllLocalData();
      if (!mounted) return;
      widget.onAllDataDeleted?.call();
      if (widget.onAllDataDeleted == null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('All local data deleted')),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to delete data: $e')),
      );
    }
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

class _InlineSubSettingsAppBar extends StatelessWidget
    implements PreferredSizeWidget {
  final String title;
  final VoidCallback onBack;
  const _InlineSubSettingsAppBar({
    required this.title,
    required this.onBack,
  });

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
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                IconButton(
                  onPressed: onBack,
                  icon: const Icon(Icons.arrow_back, color: AppColors.textPrimary),
                ),
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                      letterSpacing: -0.2,
                      color: AppColors.textPrimary,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
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

class _SettingsNavTile extends StatelessWidget {
  final IconData icon;
  final Color iconBgColor;
  final String title;
  final VoidCallback onTap;

  const _SettingsNavTile({
    required this.icon,
    required this.iconBgColor,
    required this.title,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      splashColor: AppColors.bgSurfaceActive,
      highlightColor: AppColors.bgSurfaceActive.withAlpha(120),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: iconBgColor,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(icon, size: 20, color: Colors.white.withValues(alpha: 0.9)),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                title,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w400,
                  color: AppColors.textPrimary,
                ),
              ),
            ),
            const Icon(
              Icons.chevron_right_rounded,
              color: AppColors.textSecondary,
            ),
          ],
        ),
      ),
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

// ── Node editor bottom sheet ──────────────────────────────────────────────────

class _NodeEditorSheet extends StatefulWidget {
  final NodeConfig? existing;
  final String baseId;
  final String? accountIdForNew;
  final SettingsRepository settings;
  final void Function(NodeConfig) onSave;

  const _NodeEditorSheet({
    required this.existing,
    required this.baseId,
    this.accountIdForNew,
    required this.settings,
    required this.onSave,
  });

  @override
  State<_NodeEditorSheet> createState() => _NodeEditorSheetState();
}

class _NodeEditorSheetState extends State<_NodeEditorSheet> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _hostCtrl;

  SgtpTransportFamily _transport = SgtpTransportFamily.tcp;
  bool _useTls = false;
  SgtpServerOptions? _serverOptions;
  DateTime? _serverOptionsAt;
  bool _optionsLoading = false;
  String? _optionsError;
  Timer? _fetchTimer;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _nameCtrl = TextEditingController(text: e?.name ?? '');
    _hostCtrl = TextEditingController(text: e?.host ?? '');
    _transport = SgtpTransportFamilyCodec.resolve(
        e?.transport ?? SgtpTransportFamily.tcp);
    _useTls = e?.useTls ?? false;

    _hostCtrl.addListener(_scheduleFetch);

    if (e != null) unawaited(_loadCachedOptions());
  }

  Future<void> _loadCachedOptions() async {
    final opts = await widget.settings.loadNodeServerOptions(widget.baseId);
    final at =
        await widget.settings.loadNodeServerOptionsSavedAt(widget.baseId);
    if (!mounted || opts == null) return;
    setState(() {
      _serverOptions = opts;
      _serverOptionsAt = at;
    });
  }

  void _scheduleFetch() {
    _fetchTimer?.cancel();
    _fetchTimer = Timer(const Duration(milliseconds: 600), _refreshOptions);
  }

  Future<void> _refreshOptions() async {
    final host = _hostCtrl.text
        .trim()
        .replaceAll(RegExp(r'^https?://', caseSensitive: false), '')
        .replaceAll(RegExp(r'^wss?://', caseSensitive: false), '')
        .trim();
    if (host.isEmpty) return;

    if (!mounted) return;
    setState(() {
      _optionsLoading = true;
      _optionsError = null;
    });
    try {
      final (:opts, port: _, tls: _) = await SgtpServerDiscovery.discover(host);
      await widget.settings.saveNodeServerOptions(widget.baseId, opts);
      final savedAt =
          await widget.settings.loadNodeServerOptionsSavedAt(widget.baseId);
      if (!mounted) return;
      setState(() {
        _serverOptions = opts;
        _serverOptionsAt = savedAt ?? DateTime.now();
        _optionsLoading = false;
        if (_useTls && !_tlsAvailable()) _useTls = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _optionsLoading = false;
        _optionsError = 'Failed to fetch: $e';
      });
    }
  }

  bool _tlsAvailable() =>
      _serverOptions?.supports(_transport, tls: true) == true;

  void _save() {
    final name = _nameCtrl.text.trim();
    final host = _hostCtrl.text
        .trim()
        .replaceAll(RegExp(r'^https?://', caseSensitive: false), '')
        .replaceAll(RegExp(r'^wss?://', caseSensitive: false), '')
        .trim();
    if (name.isEmpty || host.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please fill in all fields')),
      );
      return;
    }
    widget.onSave(NodeConfig(
      id: widget.baseId,
      accountId: widget.existing?.accountId ?? widget.accountIdForNew ?? '',
      name: name,
      host: host,
      chatPort: 443,
      voicePort: 443,
      transport: _transport,
      useTls: _useTls,
    ));
  }

  @override
  void dispose() {
    _fetchTimer?.cancel();
    _nameCtrl.dispose();
    _hostCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
            20, 24, 20, MediaQuery.of(context).viewInsets.bottom + 24),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                widget.existing == null ? 'Add Server' : 'Edit Server',
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 24),

              _StyledField(
                controller: _nameCtrl,
                icon: Icons.badge_outlined,
                hint: 'Server Name',
              ),
              const SizedBox(height: 12),

              _StyledField(
                controller: _hostCtrl,
                icon: Icons.dns_outlined,
                hint: 'Server Address (IP or Domain)',
              ),
              const SizedBox(height: 12),

              const SizedBox(height: 12),

              StyledDropdown<SgtpTransportFamily>(
                icon: Icons.cable_outlined,
                options: [
                  for (final f in availableTransportFamilies)
                    DropdownOption(
                      value: f,
                      label: switch (f) {
                        SgtpTransportFamily.tcp => 'TCP',
                        SgtpTransportFamily.http => 'HTTP',
                        SgtpTransportFamily.websocket => 'WebSocket',
                      },
                    ),
                ],
                value: _transport,
                onChanged: (v) => setState(() {
                  _transport = v;
                  if (_useTls && !_tlsAvailable()) _useTls = false;
                }),
              ),
              const SizedBox(height: 12),

              // TLS toggle row
              Container(
                decoration: BoxDecoration(
                  color: const Color(0xFF1B1B1F),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppColors.border),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    const Icon(Icons.lock_outline,
                        size: 22, color: AppColors.textSecondary),
                    const SizedBox(width: 12),
                    const Expanded(
                      child: Text(
                        'TLS',
                        style: TextStyle(
                            color: AppColors.textPrimary, fontSize: 15),
                      ),
                    ),
                    Switch(
                      value: _useTls,
                      onChanged: _tlsAvailable()
                          ? (v) => setState(() => _useTls = v)
                          : null,
                      activeColor: Colors.white,
                      activeTrackColor: const Color(0xFF34C759),
                      inactiveTrackColor: AppColors.border,
                      inactiveThumbColor: Colors.white,
                    ),
                  ],
                ),
              ),

              // Status line
              if (_optionsLoading) ...[
                const SizedBox(height: 10),
                Row(
                  children: [
                    SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: AppColors.textSecondary),
                    ),
                    const SizedBox(width: 8),
                    const Text(
                      'Fetching server options…',
                      style: TextStyle(
                          color: AppColors.textSecondary, fontSize: 12),
                    ),
                  ],
                ),
              ] else if (_optionsError != null) ...[
                const SizedBox(height: 10),
                Text(
                  _optionsError!,
                  style:
                      const TextStyle(color: AppColors.statusRed, fontSize: 12),
                ),
              ] else if (_serverOptions != null) ...[
                const SizedBox(height: 10),
                Text(
                  'Available: ${_serverOptions!.availableLabels().join(", ")}'
                  '${_serverOptionsAt != null ? " (cached)" : ""}',
                  style: const TextStyle(
                      color: AppColors.textSecondary, fontSize: 12),
                ),
              ],

              const SizedBox(height: 24),
              _SheetBtn(label: 'Save Server', onTap: _save),
            ],
          ),
        ),
      ),
    );
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
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: fg)),
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
                    contentPadding: const EdgeInsets.symmetric(vertical: 14),
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
                style:
                    const TextStyle(fontSize: 12, color: AppColors.statusRed)),
          ),
        ],
      ],
    );
  }
}

// ── Account switcher widgets ──────────────────────────────────────────────────

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
            UserAvatar(bytes: profileAvatar, name: displayName, size: 42),
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
                  const Text(
                    'Account profile',
                    style:
                        TextStyle(fontSize: 13, color: AppColors.textSecondary),
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
              const Icon(Icons.check_circle, size: 20, color: Color(0xFF0A84FF))
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
