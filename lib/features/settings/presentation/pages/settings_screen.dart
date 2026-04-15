import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:camera/camera.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:sgtp_camera/sgtp_camera.dart';

import 'package:sgtp_flutter/core/app_theme.dart';
import 'package:sgtp_flutter/core/widgets/app_bottom_sheet.dart';
import 'package:sgtp_flutter/core/qr_data.dart';
import 'package:sgtp_flutter/core/sgtp_server_options.dart';
import 'package:sgtp_flutter/core/sgtp_transport.dart';
import 'package:sgtp_flutter/core/uuid_v7.dart';
import 'package:sgtp_flutter/core/file_save.dart';
import 'package:logging/logging.dart';
import 'package:sgtp_flutter/core/constants.dart';
import 'package:sgtp_flutter/features/settings/presentation/widgets/pretty_qr_share_panel.dart';
import 'package:sgtp_flutter/features/settings/presentation/widgets/styled_dropdown.dart';
import 'package:sgtp_flutter/features/contacts/presentation/widgets/user_avatar.dart';
import 'package:sgtp_flutter/features/settings/presentation/pages/logs_page.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:sgtp_flutter/features/settings/application/models/settings_models.dart';
import 'package:sgtp_flutter/features/settings/application/models/app_storage_models.dart';
import 'package:sgtp_flutter/features/settings/application/models/usage_stats_models.dart';
import 'package:sgtp_flutter/features/settings/application/services/settings_management_service.dart';
import 'package:sgtp_flutter/features/settings/application/viewmodels/settings_cubit.dart';
import 'package:sgtp_flutter/features/settings/application/viewmodels/settings_view_state.dart';
import 'package:sgtp_flutter/features/messaging/domain/repositories/chat_storage_gateway.dart';

enum _SettingsSection {
  key,
  chats,
  system,
  data,
  help,
}

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final SettingsCubit _cubit;
  SettingsManagementService get _settings => _cubit.settings;

  final _logsCountNotifier = _LogsCountNotifier();
  final _nicknameCtrl = TextEditingController();
  final _usernameCtrl = TextEditingController();

  bool _captureDevicesLoading = false;
  List<InputDevice> _microphones = const [];
  String? _selectedMicrophoneId;
  List<_CameraOption> _cameras = const [];

  String? _selectedCameraName;
  CameraController? _cameraCheckController;
  final AudioRecorder _micCheckRecorder = AudioRecorder();
  final AudioPlayer _micCheckPlayer = AudioPlayer();
  Timer? _micCheckTimer;
  bool _micCheckEnabled = false;
  bool _micCheckInFlight = false;
  bool _cameraCheckEnabled = false;
  bool _cameraCheckLoading = false;
  String? _cameraCheckError;
  int _cameraCheckToken = 0;

  bool _accountsExpanded = false;
  _SettingsSection? _activeSection;
  bool _serversExpanded = false;
  String? _lastSyncedAccountId;

  bool get _isDesktop =>
      !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

  @override
  void initState() {
    super.initState();
    _cubit = context.read<SettingsCubit>();
    if (_isDesktop) {
      SgtpCamera.init();
    }
    _syncControllersFromState(_cubit.state);
  }

  /// Sync TextEditingControllers from cubit state (called once on init and
  /// can be called from BlocListener when the active account changes).
  void _syncControllersFromState(SettingsViewState s) {
    if (_nicknameCtrl.text != s.nickname) {
      _nicknameCtrl.text = s.nickname;
    }
    if (_usernameCtrl.text != s.username) {
      _usernameCtrl.text = s.username;
    }
    // Reload capture devices only when the active account changes.
    final accountId = s.activeAccountId;
    if (accountId != _lastSyncedAccountId) {
      _lastSyncedAccountId = accountId;
      if (accountId != null && accountId.isNotEmpty) {
        unawaited(_loadCaptureDevicesForAccount(accountId));
      }
    }
  }

  String? _activeAccountId() => _cubit.state.activeAccountId;

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
    if (_isDesktop && _cameraCheckEnabled) {
      SgtpCamera.close();
    }
    _nicknameCtrl.dispose();
    _usernameCtrl.dispose();
    _logsCountNotifier.dispose();
    super.dispose();
  }

  Future<void> _loadCaptureDevicesForAccount(String accountId) async {
    if (accountId.trim().isEmpty) return;
    await _setMicrophoneCheckEnabled(false);
    await _setCameraCheckEnabled(false);
    if (mounted) setState(() => _captureDevicesLoading = true);

    List<InputDevice> microphones = const [];
    List<_CameraOption> cameras = const [];
    try {
      microphones = await AudioRecorder().listInputDevices();
    } catch (_) {}
    try {
      if (_isDesktop) {
        cameras = SgtpCamera.enumerate()
            .map((cam) => _CameraOption(
                  id: cam.id,
                  label: cam.displayName,
                ))
            .toList(growable: false);
      } else {
        cameras = (await availableCameras())
            .map((cam) => _CameraOption(
                  id: cam.name,
                  label: _cameraLabelForMobile(cam),
                  mobileInfo: cam,
                ))
            .toList(growable: false);
      }
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
      if (cam.id == savedCameraName) {
        selectedCameraName = cam.id;
        break;
      }
    }
    selectedCameraName ??= cameras.isNotEmpty ? cameras.first.id : null;

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

  String _cameraLabelForMobile(CameraDescription cam) {
    final lens = switch (cam.lensDirection) {
      CameraLensDirection.front => 'Front',
      CameraLensDirection.back => 'Back',
      CameraLensDirection.external => 'External',
    };
    return '$lens (${cam.name})';
  }

  Future<void> _selectMicrophone(String id) async {
    await _cubit.savePreferredMicrophone(id);
    if (!mounted) return;
    setState(() => _selectedMicrophoneId = id);
    if (_micCheckEnabled) {
      await _setMicrophoneCheckEnabled(true, restart: true);
    }
  }

  Future<void> _selectCamera(String name) async {
    await _cubit.savePreferredCamera(name);
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
    if (_isDesktop) {
      SgtpCamera.close();
    }

    if (!enabled) {
      if (mounted) setState(() {});
      return;
    }

    final selectedId = _selectedCameraName;
    if (selectedId == null || selectedId.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Select a camera first')),
        );
      }
      return;
    }
    _CameraOption? selectedCamera;
    for (final cam in _cameras) {
      if (cam.id == selectedId) {
        selectedCamera = cam;
        break;
      }
    }
    final cameraExists = selectedCamera != null;
    if (!cameraExists) {
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
      if (_isDesktop) {
        final result = SgtpCamera.open(deviceId: selectedId);
        if (!mounted || token != _cameraCheckToken || !_cameraCheckEnabled) {
          SgtpCamera.close();
          return;
        }
        if (result != 0) {
          setState(() {
            _cameraCheckEnabled = false;
            _cameraCheckLoading = false;
            _cameraCheckError = 'Failed to open camera (error $result)';
          });
          return;
        }
        setState(() {
          _cameraCheckLoading = false;
        });
      } else {
        final mobile = selectedCamera.mobileInfo;
        if (mobile == null) {
          setState(() {
            _cameraCheckEnabled = false;
            _cameraCheckLoading = false;
            _cameraCheckError = 'Selected camera is unavailable';
          });
          return;
        }
        final controller = CameraController(
          mobile,
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
      }
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
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Could not read key file')),
          );
        }
        return;
      }
      await _cubit.importPrivateKey(accountId, bytes, name: file.name);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Invalid private key: $e')),
        );
      }
    }
  }

  void _showPrivateKeyExportSheet() {
    final bytes = _cubit.state.privateKeyBytes;
    if (bytes == null || bytes.isEmpty) return;
    final keyText = String.fromCharCodes(bytes).trim();

    showAppBottomSheet<void>(
      context,
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

    final confirm = await showAppConfirmSheet(
      context,
      title: 'Are you sure?',
      body:
          'Importing a key from clipboard will REPLACE the private key for this account.',
      confirmLabel: 'Yes',
      cancelLabel: 'No',
    );
    if (!confirm) return;

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
      await _cubit.importPrivateKeyFromText(accountId, text);
      if (!mounted) return;
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
      await _cubit.importPrivateKey(accountId, bytes, name: file.name);
      return true;
    } catch (_) {
      return false;
    }
  }

  // ── Private key: generate ────────────────────────────────────────────────

  Future<void> _generatePrivateKey() async {
    final confirm = await showAppConfirmSheet(
      context,
      title: 'Generate New Key?',
      body:
          'This will create a new Ed25519 identity key and save it to the sgtp directory.\n\n'
          'Your old key will be replaced. Peers that trusted your old key will need to add the new one to their whitelist.',
      confirmLabel: 'Generate',
    );
    if (!confirm) return;

    try {
      await _cubit.generatePrivateKey();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('New key generated and saved')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Key generation failed: $e')),
        );
      }
    }
  }

  Future<bool> _generatePrivateKeyForAccount(String accountId) async {
    try {
      await _cubit.generatePrivateKey();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _pastePrivateKeyForAccount(String accountId, String text) async {
    try {
      await _cubit.importPrivateKeyFromText(accountId, text);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _promptPrivateKeyForAccount(String accountId) async {
    if (await _cubit.hasPrivateKey(accountId)) return true;

    bool saved = false;
    String? error;
    final pasteCtrl = TextEditingController();
    if (!mounted) return false;

    await showAppBottomSheet<void>(
      context,
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
                  AppSheetButton(
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
                  AppSheetOrDivider(),
                  const SizedBox(height: 16),

                  // Generate
                  AppSheetButton(
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
                  AppSheetOrDivider(),
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
                  AppSheetButton(
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
                  AppSheetButton(
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

  // ── User avatar ───────────────────────────────────────────────────────────

  Future<void> _pickUserAvatar() async {
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
    await _cubit.setUserAvatar(bytes);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Avatar saved')),
      );
    }
  }

  Future<void> _removeUserAvatar() async {
    await _cubit.setUserAvatar(null);
  }

  // ── Helpers that read cubit state ──────────────────────────────────────────

  List<String> _accountIds(SettingsViewState s) {
    return List<String>.from(s.accountIdsList);
  }

  NodeConfig? _representativeNodeForAccount(String accountId, SettingsViewState s) {
    final id = accountId.trim();
    if (id.isEmpty) return null;
    for (final n in s.nodes) {
      if (n.effectiveAccountId == id) return n;
    }
    return null;
  }

  String _accountName(String accountId, SettingsViewState s) {
    final rep = _representativeNodeForAccount(accountId, s);
    final nick = (s.nicknamesByNodeId[accountId] ?? '').trim();
    if (nick.isNotEmpty) return nick;
    if (rep != null) return rep.name;
    if (accountId.length >= 8) return 'Account ${accountId.substring(0, 8)}';
    return 'Account';
  }

  Uint8List? _accountAvatar(String accountId, SettingsViewState s) {
    return s.avatarsByNodeId[accountId];
  }

  Future<void> _selectServer(NodeConfig node) async {
    setState(() => _serversExpanded = false);
    await _cubit.selectServer(node.id);
  }

  Future<void> _selectAccountId(String accountId) async {
    final id = accountId.trim();
    if (id.isEmpty) return;
    final previousId = _activeAccountId();
    setState(() => _accountsExpanded = false);
    await _cubit.selectAccountId(id);

    // Prevent half-switched state: without a private key we cannot apply
    // account config, and Home would continue showing previous account data.
    final s = _cubit.state;
    if (s.privateKeyBytes == null || s.myPublicKey == null) {
      if (previousId != null && previousId.isNotEmpty && previousId != id) {
        await _cubit.selectAccountId(previousId);
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'This account has no private key yet. Import or generate one first.',
          ),
        ),
      );
    }
  }

  Future<void> _deleteAccount(String accountId) async {
    final id = accountId.trim();
    if (id.isEmpty) return;
    final s = _cubit.state;
    final linkedServers =
        s.nodes.where((n) => n.accountId.trim() == id).toList();
    final label = _accountName(id, s);
    final confirmed = await showAppConfirmSheet(
      context,
      title: 'Delete Account?',
      body: 'Delete "$label"? '
          'Linked servers (${linkedServers.length}) will be kept and detached from this account. '
          'Profile/key data for this account will no longer be used.',
      confirmLabel: 'Delete',
      danger: true,
    );
    if (!confirmed) return;
    await _cubit.deleteAccount(id);
  }

  Future<void> _deleteServer(NodeConfig node) async {
    await _deleteNode(node);
  }

  NodeConfig? _selectedServerNode(SettingsViewState s) =>
      _settings.selectPreferredServer(
        nodes: s.nodes,
        preferredNodeId: s.preferredNodeId,
      );

  String _selectedServerLabel(SettingsViewState s) {
    final node = _selectedServerNode(s);
    if (node == null) return 'No servers';
    return '${node.name} (${node.chatAddress})';
  }

  String? _selectedServerId(SettingsViewState s) {
    final node = _selectedServerNode(s);
    if (node == null) return null;
    final id = node.id.trim();
    return id.isEmpty ? null : id;
  }

  // ── Nodes ────────────────────────────────────────────────────────────────

  Future<NodeConfig?> _openNodeEditor(
      {NodeConfig? existing, String? accountIdForNew}) async {
    final baseId = existing?.id ?? uuidBytesToHex(generateUUIDv7());
    NodeConfig? result;
    await showAppBottomSheet<void>(
      context,
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
    await _cubit.addServerOnly(node);
  }

  Future<void> _addAccountOnly() async {
    final accountId = uuidBytesToHex(generateUUIDv7());
    await _cubit.addEmptyAccount(accountId);
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
    await _migrateEditedServerChats(previous: node, updated: updated);
    await _cubit.editNode(updated);
  }

  String _normalizeServerKey(String raw) {
    return raw
        .trim()
        .replaceAll(RegExp(r'^https?://', caseSensitive: false), '')
        .replaceAll(RegExp(r'^wss?://', caseSensitive: false), '')
        .toLowerCase();
  }

  Future<void> _migrateEditedServerChats({
    required NodeConfig previous,
    required NodeConfig updated,
  }) async {
    final from = previous.chatAddress.trim();
    final to = updated.chatAddress.trim();
    if (from.isEmpty || to.isEmpty) return;
    if (_normalizeServerKey(from) == _normalizeServerKey(to)) return;

    final accountId = (_activeAccountId() ?? '').trim();
    if (accountId.isEmpty) return;

    final migrated =
        await context.read<ChatStorageGateway>().migrateServerAddress(
              accountId: accountId,
              fromServerAddress: from,
              toServerAddress: to,
            );
    if (!mounted || migrated <= 0) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          migrated == 1
              ? 'Moved 1 chat history to $to'
              : 'Moved $migrated chat histories to $to',
        ),
      ),
    );
  }

  Future<void> _deleteNode(NodeConfig node) async {
    bool confirmed = false;
    await showAppBottomSheet<void>(
      context,
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
                    child: AppSheetButton(
                      label: 'Cancel',
                      secondary: true,
                      onTap: () => Navigator.pop(ctx),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: AppSheetButton(
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
    await _cubit.deleteNode(node.id);
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<SettingsCubit, SettingsViewState>(
      listener: (context, state) {
        _syncControllersFromState(state);
      },
      builder: (context, state) {
        final activeSection = _activeSection;
        final subHeader = switch (activeSection) {
          _SettingsSection.chats => (
              backColor: AppColors.textPrimary,
              title: 'Chats & Media',
              titleSize: 18.0
            ),
          _SettingsSection.help => (
              backColor: const Color(0xFF0A84FF),
              title: 'Information',
              titleSize: 18.0
            ),
          _SettingsSection.key => (
              backColor: AppColors.textSecondary,
              title: 'Key Settings',
              titleSize: 20.0
            ),
          _SettingsSection.system => (
              backColor: AppColors.textSecondary,
              title: 'Logs & Debug',
              titleSize: 20.0
            ),
          _SettingsSection.data => (
              backColor: AppColors.textSecondary,
              title: 'Data',
              titleSize: 20.0
            ),
          null => null,
        };
        return Scaffold(
          backgroundColor: AppColors.bgMain,
          appBar: activeSection == null
              ? const _SettingsAppBar()
              : _InlineSubSettingsAppBar(
                  title: subHeader!.title,
                  backColor: subHeader.backColor,
                  titleSize: subHeader.titleSize,
                  onBack: () => setState(() => _activeSection = null),
                ),
          body: ListView(
            padding:
                EdgeInsets.only(top: activeSection == null ? 0 : 20, bottom: 100),
            children: activeSection == null
                ? [
                    _buildAccountSwitcher(state),
                    _buildProfileSection(state),
                    _SettingsGroup(
                        title: 'Server Connection', child: _buildNetworkCard(state)),
                    _buildSettingsHub(),
                    const SizedBox(height: 16),
                  ]
                : [
                    ..._sectionChildren(activeSection, state),
                    const SizedBox(height: 16),
                  ],
          ),
        );
      },
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
                iconBgColor: const Color(0xFF004a99),
                icon: Icons.vpn_key_outlined,
                title: 'Key Settings',
                onTap: () =>
                    setState(() => _activeSection = _SettingsSection.key),
              ),
              const Divider(height: 1, color: AppColors.border),
              _SettingsNavTile(
                iconBgColor: const Color(0xFF1a7431),
                icon: Icons.chat_bubble_outline_rounded,
                title: 'Chats & Media',
                onTap: () =>
                    setState(() => _activeSection = _SettingsSection.chats),
              ),
              const Divider(height: 1, color: AppColors.border),
              _SettingsNavTile(
                iconBgColor: const Color(0xFF995a00),
                icon: Icons.storage_rounded,
                title: 'Data',
                onTap: () =>
                    setState(() => _activeSection = _SettingsSection.data),
              ),
              const Divider(height: 1, color: AppColors.border),
              _SettingsNavTile(
                iconBgColor: const Color(0xFF6a308a),
                icon: Icons.bug_report_outlined,
                title: 'Logs & Debug',
                onTap: () =>
                    setState(() => _activeSection = _SettingsSection.system),
              ),
              const Divider(height: 1, color: AppColors.border),
              _SettingsNavTile(
                iconBgColor: const Color(0xFF4a4a4f),
                icon: Icons.info_outline_rounded,
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

  List<Widget> _sectionChildren(_SettingsSection section, SettingsViewState state) => switch (section) {
        _SettingsSection.key => [
            _SettingsGroup(
              title: 'Private Key (Ed25519)',
              child: _buildPrivateKeyCard(state),
            ),
          ],
        _SettingsSection.chats => [
            _RoundedSettingsSection(
              title: 'Interaction',
              child: _buildInteractionCard(state),
            ),
            _RoundedSettingsSection(
              title: 'Media & Devices',
              child: _buildMediaCard(state),
            ),
          ],
        _SettingsSection.system => [
            _SettingsGroup(title: 'Logs', child: _buildLogsCard()),
          ],
        _SettingsSection.data => [
            _SettingsGroup(title: 'Data', child: _buildDataCard(state)),
          ],
        _SettingsSection.help => [
            _buildInfoHero(),
            _RoundedSettingsSection(
              title: 'About App',
              child: _buildAboutCard(),
            ),
            _RoundedSettingsSection(
              title: 'Quick Start Guide',
              child: _buildQuickStartCard(),
            ),
            const Padding(
              padding: EdgeInsets.only(top: 4, bottom: 20),
              child: Center(
                child: Text(
                  'Secure Gossip Transfer Protocol',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppColors.textSecondary,
                  ),
                ),
              ),
            ),
          ],
      };

  // ── Profile section ───────────────────────────────────────────────────────

  Future<void> _saveNickname(String value) async {
    await _cubit.saveNickname(value.trim());
  }

  Future<void> _saveUsername(String value) async {
    // Strip leading @ if user typed it, sanitize
    final stripped = value.trim().replaceFirst(RegExp(r'^@'), '');
    final sanitized = stripped
        .replaceAll(RegExp(r'[^A-Za-z0-9_]'), '')
        .substring(
          0,
          stripped.replaceAll(RegExp(r'[^A-Za-z0-9_]'), '').length.clamp(0, 32),
        );
    await _cubit.saveUsername(sanitized);
  }

  void _showMyProfileShare() {
    final s = _cubit.state;
    if (s.myPublicKey == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No public key loaded yet')),
      );
      return;
    }
    final hexKey =
        s.myPublicKey!.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    final nickname = s.nickname;
    final shareData = QrShareData(
      type: 'profile',
      publicKeyHex: hexKey,
      nickname: nickname.isEmpty ? null : nickname,
      timestamp: DateTime.now().millisecondsSinceEpoch,
    );

    showAppBottomSheet<void>(
      context,
      builder: (ctx) => SafeArea(
        child: PrettyQrSharePanel(
          data: shareData,
          title: nickname.isEmpty ? 'My Profile' : nickname,
          subtitle:
              '${hexKey.substring(0, 8)}…${hexKey.substring(hexKey.length - 8)}',
          description:
              'Share this so others can add you as a contact without typing your key manually.',
          copyMessage: 'Profile hex copied',
          exportName: nickname.isEmpty
              ? 'my-profile'
              : 'profile-${nickname.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-')}',
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

    showAppBottomSheet<void>(
      context,
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

  String _formatBytes(int bytes) {
    final value = bytes.toDouble();
    if (value < 1024) return '$bytes B';
    final kb = value / 1024.0;
    if (kb < 1024) return '${kb.toStringAsFixed(kb < 10 ? 1 : 0)} KB';
    final mb = kb / 1024.0;
    if (mb < 1024) return '${mb.toStringAsFixed(mb < 10 ? 1 : 0)} MB';
    final gb = mb / 1024.0;
    return '${gb.toStringAsFixed(gb < 10 ? 1 : 0)} GB';
  }

  Widget _usageTile(String label, UsageStat stat) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF1B1B1F),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: AppColors.textPrimary,
              ),
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                '${stat.requests} req',
                style: const TextStyle(
                  fontSize: 13,
                  color: AppColors.textSecondary,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                'in ${_formatBytes(stat.bytesIn)} · out ${_formatBytes(stat.bytesOut)}',
                style: const TextStyle(
                  fontSize: 13,
                  color: AppColors.textSecondary,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _storageRow(String label, int bytes) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: const TextStyle(fontSize: 14, color: AppColors.textPrimary),
            ),
          ),
          Text(
            _formatBytes(bytes),
            style: const TextStyle(fontSize: 14, color: AppColors.textSecondary),
          ),
        ],
      ),
    );
  }

  void _showUsageSheet() {
    showAppBottomSheet<void>(
      context,
      builder: (ctx) => SafeArea(
        child: DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.85,
          minChildSize: 0.5,
          maxChildSize: 0.95,
          builder: (ctx, controller) => SingleChildScrollView(
            controller: controller,
            physics: const ClampingScrollPhysics(),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 24, 20, 16),
              child: SizedBox(
                width: double.infinity,
                child: FutureBuilder<UsageStatsSummary>(
                  future: _cubit.loadMyUsageStats(),
                  builder: (ctx, snap) {
                    final child = switch (snap.connectionState) {
                      ConnectionState.none ||
                      ConnectionState.waiting =>
                        const Center(
                          child: Padding(
                            padding: EdgeInsets.symmetric(vertical: 24),
                            child: CircularProgressIndicator(),
                          ),
                        ),
                      _ => snap.hasError
                          ? Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'Usage',
                                  style: TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.w700,
                                    color: AppColors.textPrimary,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  'Failed to load usage stats: ${snap.error}',
                                  style: const TextStyle(
                                      fontSize: 14,
                                      color: AppColors.statusRed),
                                ),
                                const SizedBox(height: 16),
                                AppSheetButton(
                                  label: 'Close',
                                  secondary: true,
                                  onTap: () => Navigator.of(ctx).pop(),
                                ),
                              ],
                            )
                          : () {
                              final s = snap.data!;
                              return Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      const Expanded(
                                        child: Text(
                                          'Usage',
                                          style: TextStyle(
                                            fontSize: 18,
                                            fontWeight: FontWeight.w700,
                                            color: AppColors.textPrimary,
                                          ),
                                        ),
                                      ),
                                      GestureDetector(
                                        onTap: () => Navigator.of(ctx).pop(),
                                        child: const SizedBox(
                                          width: 36,
                                          height: 36,
                                          child: Icon(Icons.close,
                                              size: 20,
                                              color: AppColors.textSecondary),
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 4),
                                  const Text(
                                    'Buckets are calculated in UTC.',
                                    style: TextStyle(
                                        fontSize: 13,
                                        color: AppColors.textSecondary),
                                  ),
                                  const SizedBox(height: 16),
                                  _usageTile('Minute', s.minute),
                                  const SizedBox(height: 10),
                                  _usageTile('Hour', s.hour),
                                  const SizedBox(height: 10),
                                  _usageTile('Day', s.day),
                                  const SizedBox(height: 10),
                                  _usageTile('Week', s.week),
                                  const SizedBox(height: 10),
                                  _usageTile('Month', s.month),
                                  const SizedBox(height: 10),
                                  _usageTile('All time', s.allTime),
                                  const SizedBox(height: 16),
                                  const Divider(
                                      height: 1, color: AppColors.border),
                                  const SizedBox(height: 16),
                                  const Text(
                                    'App storage (local)',
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w700,
                                      color: AppColors.textPrimary,
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  const Text(
                                    'This is the disk space used by the app on this device.',
                                    style: TextStyle(
                                        fontSize: 13,
                                        color: AppColors.textSecondary),
                                  ),
                                  const SizedBox(height: 12),
                                  FutureBuilder<AppStorageBreakdown>(
                                    future: _cubit.loadAppStorageBreakdown(),
                                    builder: (ctx, snap) {
                                      if (snap.connectionState ==
                                              ConnectionState.waiting ||
                                          snap.connectionState ==
                                              ConnectionState.none) {
                                        return const Padding(
                                          padding: EdgeInsets.symmetric(
                                              vertical: 12),
                                          child: Center(
                                            child: CircularProgressIndicator(),
                                          ),
                                        );
                                      }
                                      if (snap.hasError || snap.data == null) {
                                        return Text(
                                          'Failed to calculate storage usage: ${snap.error}',
                                          style: const TextStyle(
                                              fontSize: 13,
                                              color: AppColors.statusRed),
                                        );
                                      }

                                      final b = snap.data!;
                                      return Column(
                                        mainAxisSize: MainAxisSize.min,
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          _storageRow('Total', b.totalBytes),
                                          _storageRow(
                                            'Persistent (docs + support)',
                                            b.persistentBytes,
                                          ),
                                          _storageRow(
                                            'Temporary artifacts',
                                            b.tempBytes,
                                          ),
                                          const SizedBox(height: 10),
                                          const Text(
                                            'Media cache',
                                            style: TextStyle(
                                              fontSize: 14,
                                              fontWeight: FontWeight.w700,
                                              color: AppColors.textPrimary,
                                            ),
                                          ),
                                          _storageRow(
                                            'Images',
                                            b.mediaImagesBytes,
                                          ),
                                          _storageRow(
                                            'Videos',
                                            b.mediaVideosBytes,
                                          ),
                                          _storageRow(
                                            'Other media',
                                            b.mediaOtherBytes,
                                          ),
                                          const SizedBox(height: 10),
                                          const Text(
                                            'Chats',
                                            style: TextStyle(
                                              fontSize: 14,
                                              fontWeight: FontWeight.w700,
                                              color: AppColors.textPrimary,
                                            ),
                                          ),
                                          _storageRow(
                                            'Message history',
                                            b.chatHistoryBytes,
                                          ),
                                          _storageRow(
                                            'Chat metadata',
                                            b.chatMetadataBytes,
                                          ),
                                          const SizedBox(height: 10),
                                          const Text(
                                            'Accounts & config',
                                            style: TextStyle(
                                              fontSize: 14,
                                              fontWeight: FontWeight.w700,
                                              color: AppColors.textPrimary,
                                            ),
                                          ),
                                          _storageRow(
                                            'MLS state',
                                            b.mlsStateBytes,
                                          ),
                                          _storageRow(
                                            'Accounts (other)',
                                            b.accountsOtherBytes,
                                          ),
                                          _storageRow(
                                            'Shared SGTP data',
                                            b.sharedSgtpBytes,
                                          ),
                                          _storageRow(
                                            'App support (prefs/db)',
                                            b.appSupportBytes,
                                          ),
                                          _storageRow(
                                            'Other documents',
                                            b.docsOtherBytes,
                                          ),
                                        ],
                                      );
                                    },
                                  ),
                                  const SizedBox(height: 16),
                                  AppSheetButton(
                                    label: 'Close',
                                    secondary: true,
                                    onTap: () => Navigator.of(ctx).pop(),
                                  ),
                                ],
                              );
                            }(),
                    };

                    return AnimatedSwitcher(
                      duration: const Duration(milliseconds: 150),
                      child: child,
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildProfileSection(SettingsViewState state) {
    final nickname = state.nickname;
    final userAvatar = state.userAvatar;
    final usernameError = state.usernameError;
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
                  name: nickname.isNotEmpty ? nickname : 'Me',
                  bytes: userAvatar,
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
                    color: usernameError != null
                        ? AppColors.statusRed
                        : AppColors.border),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(
                    color: usernameError != null
                        ? AppColors.statusRed
                        : AppColors.border),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(
                    color: usernameError != null
                        ? AppColors.statusRed
                        : AppColors.textSecondary),
              ),
              contentPadding: const EdgeInsets.symmetric(vertical: 14),
            ),
          ),
          if (usernameError != null) ...[
            const SizedBox(height: 6),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                usernameError,
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
          const SizedBox(height: 12),

          // ── Usage button ────────────────────────────────────────────────
          GestureDetector(
            onTap: _showUsageSheet,
            child: Container(
              height: 48,
              decoration: BoxDecoration(
                color: AppColors.bgSurfaceActive,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.border),
              ),
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.data_usage_outlined,
                      size: 20, color: AppColors.textPrimary),
                  SizedBox(width: 8),
                  Text(
                    'Usage',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary,
                    ),
                  ),
                ],
              ),
            ),
          ),

          // ── Remove avatar ────────────────────────────────────────────────
          if (userAvatar != null) ...[
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

  Widget _buildAccountSwitcher(SettingsViewState state) {
    final accountIds = _accountIds(state);
    final activeAccountId = state.activeAccountId;
    final activeName =
        activeAccountId != null ? _accountName(activeAccountId, state) : 'No accounts';
    final activeAvatar =
        activeAccountId != null ? _accountAvatar(activeAccountId, state) : null;
    final nickname = state.nickname;
    final userAvatar = state.userAvatar;

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
                    bytes: userAvatar ?? activeAvatar,
                    name: nickname.isNotEmpty ? nickname : activeName,
                    size: 42,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: state.nodesLoading
                        ? const Text('Loading…',
                            style: TextStyle(
                                fontSize: 15, color: AppColors.textSecondary))
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                nickname.isNotEmpty ? nickname : activeName,
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
          // ── Dropdown ───────────────────────────────────────────────────
          if (_accountsExpanded) ...[
            const Divider(height: 1, thickness: 1, color: AppColors.border),
            Column(
              children: [
                ...accountIds.map((id) {
                  final rep = _representativeNodeForAccount(id, state);
                  final displayNode = rep ??
                      NodeConfig(
                        id: id,
                        accountId: id,
                        name: _accountName(id, state),
                        host: '',
                        chatPort: 443,
                        voicePort: 443,
                      );
                  return _AccountDropdownItem(
                    node: displayNode,
                    isActive: id == activeAccountId,
                    profileAvatar: _accountAvatar(id, state),
                    profileName: _accountName(id, state),
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
    showAppBottomSheet<void>(
      context,
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

  Widget _buildPrivateKeyCard(SettingsViewState state) {
    final pubHex =
        state.myPublicKey?.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          state.privateKeyPath ?? 'No key loaded',
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
              onPressed: state.isLoading ? null : _pickPrivateKey,
            ),
            _ActionButton(
              icon: Icons.key_outlined,
              label: 'Generate',
              loading: state.isGenerating,
              onPressed:
                  (state.isLoading || state.isGenerating) ? null : _generatePrivateKey,
            ),
            _ActionButton(
              icon: Icons.content_paste_outlined,
              label: 'Import',
              onPressed: (state.isLoading || _activeAccountId() == null)
                  ? null
                  : _importPrivateKeyFromClipboard,
            ),
            _ActionButton(
              icon: Icons.upload_outlined,
              label: 'Export',
              onPressed: (state.isLoading || state.privateKeyBytes == null)
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

  // ── Network card ──────────────────────────────────────────────────────────

  Widget _buildNetworkCard(SettingsViewState state) {
    final selectedServer = _selectedServerNode(state);
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
                    _selectedServerLabel(state),
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
                ...state.nodes.map((n) {
                  final isSelected = n.id == _selectedServerId(state);
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
            style:
                const TextStyle(color: AppColors.textSecondary, fontSize: 12),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    if (!_isDesktop) {
      final controller = _cameraCheckController;
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
    return Align(
      alignment: Alignment.topLeft,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: const SizedBox(
          width: 156,
          height: 156,
          child: _SgtpCameraPreview(),
        ),
      ),
    );
  }

  Widget _buildMediaCard(SettingsViewState state) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SwitchRow(
          label: 'Compress files',
          subtitle: 'Reduce outgoing file size',
          value: state.compressFiles,
          onChanged: (v) {
            unawaited(_cubit.saveMediaSettings(compressFiles: v));
          },
        ),
        const SizedBox(height: 12),
        const Text(
          'Outgoing media chunk size',
          style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: SgtpConstants.allowedMediaChunkSizes.map((size) {
            final selected = state.mediaChunkSizeBytes == size;
            final kb = size ~/ 1024;
            return _ChoiceChip(
              label: '$kb KB',
              selected: selected,
              onTap: () {
                unawaited(_cubit.saveMediaSettings(mediaChunkSizeBytes: size));
              },
            );
          }).toList(),
        ),
        const SizedBox(height: 16),
        const Padding(
          padding: EdgeInsets.only(top: 2, bottom: 8),
          child: Text(
            'VOICE & VIDEO',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: AppColors.textPrimary,
            ),
          ),
        ),
        const Text(
          'Microphone',
          style: TextStyle(fontSize: 15, color: AppColors.textPrimary),
        ),
        const SizedBox(height: 8),
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
          if (_microphones.isEmpty)
            const _StatusBox(text: 'No microphones found')
          else ...[
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
            const SizedBox(height: 12),
          ],
          _SwitchRow(
            label: 'Microphone check',
            value: _micCheckEnabled,
            onChanged: _selectedMicrophoneId != null && _microphones.isNotEmpty
                ? (v) => unawaited(_setMicrophoneCheckEnabled(v))
                : null,
          ),
          const SizedBox(height: 14),
          const Text(
            'Camera',
            style: TextStyle(fontSize: 15, color: AppColors.textPrimary),
          ),
          const SizedBox(height: 8),
          if (_cameras.isEmpty)
            const _StatusBox(text: 'No cameras found')
          else ...[
            _buildCaptureDropdown(
              value: _selectedCameraName,
              items: _cameras
                  .map(
                    (cam) => DropdownMenuItem<String>(
                      value: cam.id,
                      child: Text(cam.label),
                    ),
                  )
                  .toList(),
              onChanged: (name) {
                if (name == null) return;
                unawaited(_selectCamera(name));
              },
            ),
            const SizedBox(height: 12),
          ],
          _SwitchRow(
            label: 'Camera check preview',
            value: _cameraCheckEnabled,
            onChanged: _selectedCameraName != null && _cameras.isNotEmpty
                ? (v) => unawaited(_setCameraCheckEnabled(v))
                : null,
          ),
          if (_cameraCheckEnabled ||
              _cameraCheckLoading ||
              _cameraCheckError != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: _buildCameraCheckPreview(),
            ),
        ],
      ],
    );
  }

  // ── Interaction card ──────────────────────────────────────────────────────

  Widget _buildInteractionCard(SettingsViewState state) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── Swipe to reply (mobile) ─────────────────────────────────────
        _SwitchRow(
          label: 'Swipe right to reply',
          value: state.swipeToReply,
          onChanged: (v) {
            _cubit.setSwipeToReply(v);
          },
        ),
        const SizedBox(height: 8),
        // ── Long-press shows full menu ──────────────────────────────────
        _SwitchRow(
          label: 'Long-press menu',
          subtitle: 'Show reactions and reply options',
          value: state.longPressMenu,
          onChanged: (v) {
            _cubit.setLongPressMenu(v);
          },
        ),
        const SizedBox(height: 12),
        // ── Desktop double-click action ─────────────────────────────────
        const Text(
          'Desktop double-click action',
          style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _ChoiceChip(
              label: 'Open reactions',
              selected: state.doubleTapDesktop == 'react',
              onTap: () {
                _cubit.setDoubleTapDesktop('react');
              },
            ),
            _ChoiceChip(
              label: 'Set reply',
              selected: state.doubleTapDesktop == 'reply',
              onTap: () {
                _cubit.setDoubleTapDesktop('reply');
              },
            ),
          ],
        ),
        const SizedBox(height: 16),
        // ── Ping interval ───────────────────────────────────────────────
        const Padding(
          padding: EdgeInsets.only(bottom: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Ping interval',
                style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
              ),
            ],
          ),
        ),
        Row(
          children: [
            Expanded(
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 4,
                  thumbShape:
                      const RoundSliderThumbShape(enabledThumbRadius: 12),
                  overlayShape:
                      const RoundSliderOverlayShape(overlayRadius: 18),
                  activeTrackColor: const Color(0xFF2C2C2E),
                  inactiveTrackColor: const Color(0xFF2C2C2E),
                  thumbColor: Colors.white,
                  overlayColor: Colors.white.withAlpha(30),
                ),
                child: Slider(
                  value: state.pingIntervalSeconds.toDouble(),
                  min: 5,
                  max: 120,
                  onChanged: (v) {
                    unawaited(_cubit.savePingInterval(v.round()));
                  },
                ),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '${state.pingIntervalSeconds}s',
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 13,
                color: AppColors.textPrimary,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ],
    );
  }

  // ── Logs card ─────────────────────────────────────────────────────────────

  Widget _buildLogsCard() {
    return ListenableBuilder(
      listenable: _logsCountNotifier,
      builder: (_, __) {
        final count = _logsCountNotifier.count;
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
                    builder: (_) => const LogsPage(),
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
        const _InfoKvRow(label: 'Version', value: '1.0.0-beta'),
        const Divider(height: 1, color: Color.fromRGBO(255, 255, 255, 0.1)),
        const _InfoKvRow(label: 'Protocol', value: 'SGTP v1'),
        const Divider(height: 1, color: Color.fromRGBO(255, 255, 255, 0.1)),
        GestureDetector(
          onTap: _launchGitHub,
          behavior: HitTestBehavior.opaque,
          child: const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Row(
              children: [
                Icon(Icons.code, size: 18, color: Color(0xFF0A84FF)),
                SizedBox(width: 8),
                Text(
                  'GitHub Repository',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                    color: Color(0xFF0A84FF),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildInfoHero() {
    return const Padding(
      padding: EdgeInsets.fromLTRB(16, 8, 16, 18),
      child: Column(
        children: [
          SizedBox(height: 4),
          _InfoAppIcon(),
          SizedBox(height: 12),
          Text(
            'SGTP Messenger',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w700,
              color: AppColors.textPrimary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildQuickStartCard() {
    const steps = [
      (
        'Generate Key',
        'Create a new secure Ed25519 private key to identify yourself.'
      ),
      (
        'Add Peers',
        'Exchange public keys with your friends and add them to whitelist.'
      ),
      (
        'Relay Server',
        'Connect to a valid SGTP relay address to start broadcasting.'
      ),
      ('Chat Securely', 'All messages are end-to-end encrypted by default.'),
    ];
    return Column(
      children: List.generate(steps.length, (i) {
        final step = steps[i];
        return Padding(
          padding: EdgeInsets.only(bottom: i == steps.length - 1 ? 0 : 16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 24,
                height: 24,
                decoration: BoxDecoration(
                  color: const Color(0xFF2C2C2E),
                  borderRadius: BorderRadius.circular(12),
                ),
                alignment: Alignment.center,
                child: Text(
                  '${i + 1}',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                  ),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: RichText(
                  text: TextSpan(
                    children: [
                      TextSpan(
                        text: '${step.$1}\n',
                        style: const TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          height: 1.3,
                        ),
                      ),
                      TextSpan(
                        text: step.$2,
                        style: const TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: 14,
                          height: 1.45,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      }),
    );
  }

  Widget _buildDataCard(SettingsViewState state) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Export your local app data into a backup file.',
          style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
        ),
        const SizedBox(height: 12),
        _ActionButton(
          icon: Icons.archive_outlined,
          label: 'Create backup',
          loading: state.isCreatingBackup,
          onPressed:
              (state.isCreatingBackup || state.isRestoringBackup) ? null : _makeBackup,
        ),
        const SizedBox(height: 16),
        const Text(
          'Restore from a backup file and merge data without duplicates.',
          style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
        ),
        const SizedBox(height: 12),
        _ActionButton(
          icon: Icons.restore,
          label: 'Restore from backup',
          loading: state.isRestoringBackup,
          onPressed: (state.isCreatingBackup || state.isRestoringBackup)
              ? null
              : _restoreFromBackupMerge,
        ),
        const SizedBox(height: 16),
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

  Future<void> _makeBackup() async {
    try {
      final backup = await _cubit.createBackup();
      final path = await FilePicker.platform.saveFile(
        dialogTitle: 'Save SGTP backup',
        fileName: backup.suggestedFileName,
        type: FileType.custom,
        allowedExtensions: const ['sgtpbackup'],
      );
      if (path == null || path.trim().isEmpty) return;
      final ok = await saveBytesToPath(path, backup.bytes);
      if (!ok) {
        throw StateError('Saving file is not supported on this platform');
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Backup saved')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to create backup: $e')),
      );
    }
  }

  Future<void> _restoreFromBackupMerge() async {
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
        throw const FormatException('Selected backup file is empty');
      }

      await _cubit.restoreFromBackup(bytes);

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Backup restored successfully')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to restore backup: $e')),
      );
    }
  }

  Future<void> _deleteAllMyData() async {
    final code = (1000 + Random().nextInt(9000)).toString();
    final ctrl = TextEditingController();
    String? err;
    var confirmed = false;
    await showAppBottomSheet<void>(
      context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => SafeArea(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
                20, 24, 20, MediaQuery.of(ctx).viewInsets.bottom + 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Delete All Data?',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  'This will permanently remove all local data from this device.',
                  style: TextStyle(
                      fontSize: 14,
                      color: AppColors.textSecondary,
                      height: 1.5),
                ),
                const SizedBox(height: 12),
                Text(
                  'Type this code to confirm: $code',
                  style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: ctrl,
                  keyboardType: TextInputType.number,
                  autofocus: true,
                  style: const TextStyle(color: AppColors.textPrimary),
                  decoration: InputDecoration(
                    hintText: 'Enter code',
                    hintStyle: const TextStyle(color: AppColors.textSecondary),
                    errorText: err,
                    filled: true,
                    fillColor: AppColors.bgSurfaceActive,
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
                      borderSide: BorderSide(
                          color: AppColors.accent.withAlpha(180), width: 1.5),
                    ),
                  ),
                  onChanged: (_) {
                    if (err != null) setS(() => err = null);
                  },
                ),
                const SizedBox(height: 20),
                Row(children: [
                  Expanded(
                    child: AppSheetButton(
                      label: 'Cancel',
                      secondary: true,
                      onTap: () => Navigator.pop(ctx),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: AppSheetButton(
                      label: 'Delete',
                      danger: true,
                      onTap: () {
                        if (ctrl.text.trim() != code) {
                          setS(() => err = 'Code does not match');
                          return;
                        }
                        confirmed = true;
                        Navigator.pop(ctx);
                      },
                    ),
                  ),
                ]),
              ],
            ),
          ),
        ),
      ),
    );
    ctrl.dispose();
    if (!confirmed) return;

    try {
      await _cubit.deleteAllData();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('All local data deleted')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to delete data: $e')),
      );
    }
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
  final Color backColor;
  final double titleSize;
  const _InlineSubSettingsAppBar({
    required this.title,
    required this.onBack,
    this.backColor = AppColors.textSecondary,
    this.titleSize = 20,
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
                  icon: Icon(Icons.arrow_back, color: backColor),
                ),
                Expanded(
                  child: Text(
                    title,
                    style: TextStyle(
                      fontSize: titleSize,
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

class _RoundedSettingsSection extends StatelessWidget {
  final String title;
  final Widget child;
  const _RoundedSettingsSection({required this.title, required this.child});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
            child: Text(
              title.toUpperCase(),
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                letterSpacing: 0.5,
                color: AppColors.textSecondary,
              ),
            ),
          ),
          Container(
            decoration: BoxDecoration(
              color: const Color(0xFF1C1C1E),
              borderRadius: BorderRadius.circular(14),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: child,
          ),
        ],
      ),
    );
  }
}

class _StatusBox extends StatelessWidget {
  final String text;
  const _StatusBox({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color.fromRGBO(255, 255, 255, 0.05),
        border: Border.all(color: const Color.fromRGBO(255, 255, 255, 0.1)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        text,
        style: const TextStyle(fontSize: 14, color: AppColors.textSecondary),
        textAlign: TextAlign.center,
      ),
    );
  }
}

class _SettingsNavTile extends StatelessWidget {
  final Color iconBgColor;
  final IconData icon;
  final String title;
  final VoidCallback onTap;

  const _SettingsNavTile({
    required this.iconBgColor,
    required this.icon,
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
              child: Center(
                child: Icon(
                  icon,
                  size: 20,
                  color: Colors.white.withValues(alpha: 0.9),
                ),
              ),
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
            const Text(
              '>',
              style: TextStyle(
                fontSize: 18,
                color: AppColors.textSecondary,
              ),
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

// ── Node editor bottom sheet ──────────────────────────────────────────────────

class _NodeEditorSheet extends StatefulWidget {
  final NodeConfig? existing;
  final String baseId;
  final String? accountIdForNew;
  final SettingsManagementService settings;
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
  late final TextEditingController _fakeSniCtrl;

  SgtpTransportFamily _transport = SgtpTransportFamily.tcp;
  bool _useTls = false;
  bool _advancedExpanded = false;
  SgtpServerOptions? _serverOptions;
  bool _optionsLoading = false;
  String? _optionsError;
  Timer? _fetchTimer;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _nameCtrl = TextEditingController(text: e?.name ?? '');
    _hostCtrl = TextEditingController(text: e?.host ?? '');
    _fakeSniCtrl = TextEditingController(text: e?.fakeSni ?? '');
    _transport = SgtpTransportFamilyCodec.resolve(
        e?.transport ?? SgtpTransportFamily.tcp);
    _useTls = e?.useTls ?? false;

    _hostCtrl.addListener(_scheduleFetch);

    unawaited(_loadAdvancedExpandedPref());
    if (e != null) unawaited(_loadCachedOptions());
  }

  Future<void> _loadAdvancedExpandedPref() async {
    final expanded = await widget.settings.loadNodeEditorAdvancedExpanded();
    if (!mounted) return;
    setState(() => _advancedExpanded = expanded);
  }

  Future<void> _loadCachedOptions() async {
    final opts = await widget.settings.loadNodeServerOptions(widget.baseId);
    if (!mounted || opts == null) return;
    setState(() {
      _serverOptions = opts;
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
      final (:opts, port: _, tls: _) =
          await widget.settings.discoverServer(host);
      if (!mounted) return;
      setState(() {
        _serverOptions = opts;
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
    final selectedPort = _resolveSelectedPort();
    widget.onSave(NodeConfig(
      id: widget.baseId,
      accountId: widget.existing?.accountId ?? widget.accountIdForNew ?? '',
      name: name,
      host: host,
      chatPort: selectedPort,
      voicePort: selectedPort,
      transport: _transport,
      useTls: _useTls,
      fakeSni: _fakeSniCtrl.text.trim(),
    ));
  }

  int _resolveSelectedPort() {
    final opts = _serverOptions;
    if (opts != null && opts.supports(_transport, tls: _useTls)) {
      final port = opts.portFor(_transport, tls: _useTls);
      if (port > 0) {
        return port;
      }
    }
    final existing = widget.existing;
    if (existing != null &&
        existing.transport == _transport &&
        existing.useTls == _useTls &&
        existing.chatPort > 0) {
      return existing.chatPort;
    }
    return _useTls ? 443 : 80;
  }

  @override
  void dispose() {
    _fetchTimer?.cancel();
    _nameCtrl.dispose();
    _hostCtrl.dispose();
    _fakeSniCtrl.dispose();
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
              const SizedBox(height: 12),

              Container(
                decoration: BoxDecoration(
                  color: const Color(0xFF1B1B1F),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppColors.border),
                ),
                child: Column(
                  children: [
                    InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () {
                        final next = !_advancedExpanded;
                        setState(() => _advancedExpanded = next);
                        unawaited(
                          widget.settings.saveNodeEditorAdvancedExpanded(next),
                        );
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 14),
                        child: Row(
                          children: [
                            const Icon(Icons.tune,
                                size: 22, color: AppColors.textSecondary),
                            const SizedBox(width: 12),
                            const Expanded(
                              child: Text(
                                'Advanced',
                                style: TextStyle(
                                    color: AppColors.textPrimary, fontSize: 15),
                              ),
                            ),
                            AnimatedRotation(
                              duration: const Duration(milliseconds: 160),
                              turns: _advancedExpanded ? 0.5 : 0,
                              child: const Icon(Icons.expand_more,
                                  color: AppColors.textSecondary),
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (_advancedExpanded) ...[
                      const Divider(
                        height: 1,
                        thickness: 1,
                        color: AppColors.border,
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Container(
                              decoration: BoxDecoration(
                                color: const Color(0x33FF9500),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(
                                  color: const Color(0x66FF9500),
                                ),
                              ),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 10,
                              ),
                              child: const Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Icon(
                                    Icons.warning_amber_rounded,
                                    size: 18,
                                    color: Color(0xFFFFB347),
                                  ),
                                  SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      'Advanced settings can break connection. '
                                      'Do not change them if you are not sure what you are doing.',
                                      style: TextStyle(
                                        color: AppColors.textPrimary,
                                        fontSize: 12,
                                        height: 1.35,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 10),
                            _StyledField(
                              controller: _fakeSniCtrl,
                              icon: Icons.shield_outlined,
                              hint: 'Fake SNI (domain)',
                            ),
                          ],
                        ),
                      ),
                    ],
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
                  'Available: ${_serverOptions!.availableLabels().join(", ")}',
                  style: const TextStyle(
                      color: AppColors.textSecondary, fontSize: 12),
                ),
              ],

              const SizedBox(height: 24),
              AppSheetButton(label: 'Save Server', onTap: _save),
            ],
          ),
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

  const _StyledField({
    required this.controller,
    required this.icon,
    required this.hint,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.bgSurfaceActive,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          Icon(icon, size: 22, color: AppColors.textSecondary),
          const SizedBox(width: 12),
          Expanded(
            child: TextField(
              controller: controller,
              style: const TextStyle(
                color: AppColors.textPrimary,
                fontSize: 15,
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

class _InfoKvRow extends StatelessWidget {
  final String label;
  final String value;
  const _InfoKvRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: const TextStyle(
              fontSize: 15,
              color: AppColors.textSecondary,
            ),
          ),
          Text(
            value,
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 14,
              color: AppColors.textPrimary,
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoAppIcon extends StatelessWidget {
  const _InfoAppIcon();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 80,
      height: 80,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF1C1C1E), Colors.black],
        ),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color.fromRGBO(255, 255, 255, 0.1)),
        boxShadow: const [
          BoxShadow(
            color: Color.fromRGBO(0, 0, 0, 0.3),
            blurRadius: 20,
            offset: Offset(0, 10),
          ),
        ],
      ),
      alignment: Alignment.center,
      child: const Text(
        'S',
        style: TextStyle(
          fontSize: 40,
          color: AppColors.textPrimary,
        ),
      ),
    );
  }
}

// Thin ChangeNotifier that fires whenever a new log record arrives,
// so the Settings "Logs" card reflects the current count in real time.
class _LogsCountNotifier extends ChangeNotifier {
  int count = 0;
  StreamSubscription<LogRecord>? _sub;

  _LogsCountNotifier() {
    _sub = Logger.root.onRecord.listen((_) {
      count++;
      notifyListeners();
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}

// ─── Interaction settings helpers ─────────────────────────────────────────────

class _SwitchRow extends StatelessWidget {
  final String label;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;
  const _SwitchRow(
      {required this.label,
      this.subtitle,
      required this.value,
      required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: subtitle == null
          ? CrossAxisAlignment.center
          : CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style:
                    const TextStyle(fontSize: 15, color: AppColors.textPrimary),
              ),
              if (subtitle != null)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    subtitle!,
                    style: const TextStyle(
                      fontSize: 13,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ),
            ],
          ),
        ),
        Switch(
          value: value,
          onChanged: onChanged,
          activeTrackColor: Colors.white,
          activeThumbColor: Colors.black,
          inactiveTrackColor: const Color(0xFF39393D),
          inactiveThumbColor: Colors.white,
          trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
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
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? Colors.white : const Color(0xFF2C2C2E),
          borderRadius: BorderRadius.circular(10),
          border:
              Border.all(color: selected ? Colors.white : Colors.transparent),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 14,
            color: selected ? Colors.black : AppColors.textPrimary,
            fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
          ),
        ),
      ),
    );
  }
}

class _CameraOption {
  final String id;
  final String label;
  final CameraDescription? mobileInfo;

  const _CameraOption({
    required this.id,
    required this.label,
    this.mobileInfo,
  });
}

// ---------------------------------------------------------------------------
// Live preview widget using SgtpCamera.previewStream
// ---------------------------------------------------------------------------

class _SgtpCameraPreview extends StatefulWidget {
  const _SgtpCameraPreview();

  @override
  State<_SgtpCameraPreview> createState() => _SgtpCameraPreviewState();
}

class _SgtpCameraPreviewState extends State<_SgtpCameraPreview> {
  StreamSubscription<CameraFrame>? _sub;
  ui.Image? _image;
  bool _decoding = false;

  @override
  void initState() {
    super.initState();
    _sub = SgtpCamera.previewStream.listen(_onFrame);
  }

  void _onFrame(CameraFrame frame) {
    if (_decoding || !mounted) return;
    _decoding = true;
    ui.decodeImageFromPixels(
      Uint8List.fromList(frame.rgba),
      frame.width,
      frame.height,
      ui.PixelFormat.rgba8888,
      (img) {
        if (!mounted) {
          img.dispose();
          _decoding = false;
          return;
        }
        setState(() {
          _image?.dispose();
          _image = img;
          _decoding = false;
        });
      },
    );
  }

  @override
  void dispose() {
    _sub?.cancel();
    _image?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final img = _image;
    if (img == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return RawImage(image: img, fit: BoxFit.cover);
  }
}
