import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kDebugMode, kIsWeb;
import 'package:sgtp_camera/sgtp_camera.dart';
import 'package:image/image.dart' as img;
import 'package:sgtp_flutter/core/app_log.dart';
import 'package:sgtp_flutter/core/interaction_prefs.dart';
import 'package:sgtp_flutter/core/platform/android_keyboard_content_loader.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:image_picker/image_picker.dart';
import 'package:pasteboard/pasteboard.dart';
import 'package:record/record.dart';

import 'package:sgtp_flutter/features/messaging/application/services/media_storage_service.dart';
import 'package:sgtp_flutter/features/messaging/application/viewmodels/chat/chat_bloc.dart';
import 'package:sgtp_flutter/features/messaging/application/viewmodels/chat/chat_event.dart';
import 'package:sgtp_flutter/features/messaging/presentation/widgets/video_note_recorder.dart';
import 'package:sgtp_flutter/features/messaging/application/viewmodels/chat/chat_state.dart';
import 'package:sgtp_flutter/features/messaging/presentation/widgets/message_bubble.dart';
import 'package:sgtp_flutter/features/messaging/presentation/widgets/room_avatar.dart';
import 'package:sgtp_flutter/core/notification_service.dart';
import 'package:sgtp_flutter/core/app_theme.dart';
import 'package:sgtp_flutter/core/widgets/app_bottom_sheet.dart';
import 'package:sgtp_flutter/features/messaging/application/models/messaging_models.dart';
import 'package:sgtp_flutter/features/settings/application/services/settings_management_service.dart';

class ChatPage extends StatefulWidget {
  final String accountId;
  const ChatPage({super.key, required this.accountId});

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> with WidgetsBindingObserver {
  final _log = AppLog('ChatPage');
  static const int _maxUploadImageDimension = 2560;
  static const int _targetUploadImageBytes = 3 * 1024 * 1024;

  late final SettingsManagementService _settingsRepo;
  late final MessagingMediaStorageService _mediaStorage;
  final _messageCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  final _recorder = AudioRecorder();
  final _focusNode = FocusNode();
  bool _infoShown = false;
  bool _isRecording = false;
  String? _recordingPath;
  List<InputDevice> _microphones = const [];
  String? _selectedMicrophoneId;
  List<CameraDeviceInfo> _desktopCameras = const [];
  String? _selectedCameraName;
  bool _hasMicrophone = false;
  bool _hasCamera = false;

  /// True when this page is in the foreground and the app is active.
  bool _isPageVisible = true;

  /// IDs of messages for which we have already dispatched a read receipt,
  /// so we don't fire it twice.
  final Set<String> _sentReadReceipts = {};

  /// Whether the text field has content (controls send vs mic button).
  bool _hasText = false;

  /// Upload progress 0.0–1.0 while sending media (null = idle).
  double? _uploadProgress;

  /// On mobile: false = voice mode 🎤, true = video note mode 🔵
  bool _isVideoNoteMode = false;

  /// True while a long-press recording is in progress (mobile hold-to-record)
  bool _isHoldRecording = false;

  ChatBloc? _chatBloc;
  int _lastMessageCount = 0;

  /// Room UUID for which we last saved/restored a scroll position.
  String _lastScrollRoomUUID = '';

  /// True after we have already restored (or skipped restoring) the saved
  /// scroll position for the current room. Prevents re-firing on every state rebuild.
  bool _scrollRestored = false;

  /// Timestamp when the app went to background. Used to decide whether
  /// to log how long the app stayed backgrounded before resuming.
  DateTime? _wentToBackground;
  static const Duration _resumeProbeMinGap = Duration(seconds: 2);

  static const _videoExtensions = {
    'mp4',
    'mov',
    'avi',
    'webm',
    'mkv',
    'm4v',
    '3gp'
  };

  // Quick emoji set for reactions
  static const _quickEmojis = [
    '👍',
    '❤️',
    '😂',
    '😮',
    '😢',
    '🔥',
    '👏',
    '🎉',
    '🤔',
    '💯'
  ];

  @override
  void initState() {
    super.initState();
    _settingsRepo = context.read<SettingsManagementService>();
    _mediaStorage = context.read<MessagingMediaStorageService>();
    _chatBloc = context.read<ChatBloc>()..add(const ChatSetVisibility(true));
    WidgetsBinding.instance.addObserver(this);
    _scrollCtrl.addListener(_onScroll);
    _loadCaptureCapabilities();
    _messageCtrl.addListener(() {
      final has = _messageCtrl.text.trim().isNotEmpty;
      if (has != _hasText) setState(() => _hasText = has);
    });
    NotificationService.init();
    NotificationService.onMarkAsRead = (messageId) {
      if (!_sentReadReceipts.contains(messageId)) {
        _sentReadReceipts.add(messageId);
        _chatBloc?.add(ChatSendMessageRead(messageId));
      }
    };
    // Flush any "Mark as Read" taps that arrived while the app was killed
    // (stored in SharedPreferences by the background isolate handler).
    NotificationService.flushPendingMarkAsRead();
  }

  @override
  void dispose() {
    _saveScrollPosition();
    _chatBloc?.add(const ChatSetVisibility(false));
    WidgetsBinding.instance.removeObserver(this);
    NotificationService.onMarkAsRead = null;
    _messageCtrl.dispose();
    _scrollCtrl.removeListener(_onScroll);
    _scrollCtrl.dispose();
    _focusNode.dispose();
    _recorder.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState appState) {
    switch (appState) {
      case AppLifecycleState.resumed:
        setState(() => _isPageVisible = true);
        _chatBloc?.add(const ChatSetVisibility(true));
        unawaited(_loadCaptureCapabilities());
        NotificationService.cancelAll();
        NotificationService.flushPendingMarkAsRead();

        final bloc = _chatBloc;
        if (bloc != null) {
          final bgDuration = _wentToBackground != null
              ? DateTime.now().difference(_wentToBackground!)
              : Duration.zero;
          _wentToBackground = null;

          // Desktop focus flips (switching between windows) often fire
          // inactive->resumed rapidly. Avoid noisy probe/reconnect storms
          // for very short gaps.
          if (bgDuration < _resumeProbeMinGap) {
            _flushPendingReadReceipts();
            break;
          }

          final status = bloc.state.status;
          if (status == ChatStatus.ready) {
            _log.info(
                '[Chat] probing live connection after background ({duration}s, status={status})',
                parameters: {
                  'duration': bgDuration.inSeconds,
                  'status': status
                });
            bloc.add(const ChatProbeConnection());
          } else if (status == ChatStatus.error &&
              !_isNonRecoverableConnectionError(bloc.state.errorMessage)) {
            // Error state may represent a broken transport session.
            // Attempt recovery automatically, but keep "disconnected" manual.
            _log.warning(
                '[Chat] reconnecting after background ({duration}s, status={status})',
                parameters: {
                  'duration': bgDuration.inSeconds,
                  'status': status
                });
            bloc.add(const ChatReconnect());
          }
        }
        _flushPendingReadReceipts();
        break;

      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
        _wentToBackground ??= DateTime.now();
        setState(() => _isPageVisible = false);
        _chatBloc?.add(const ChatSetVisibility(false));
        break;

      case AppLifecycleState.detached:
        // Do NOT disconnect here — see note in original code.
        break;
    }
  }

  bool _isNonRecoverableConnectionError(String? error) {
    final message = error ?? '';
    return message.contains('MLS welcome is missing') ||
        message.contains('MLS welcome failed') ||
        message.contains('Waiting for chat invitation');
  }

  /// Send read receipts for all messages that have not been acknowledged yet.
  /// Called when the app returns to the foreground.
  void _flushPendingReadReceipts() {
    final bloc = _chatBloc;
    final state = bloc?.state;
    if (bloc == null || state == null) return;
    for (final msg in state.messages) {
      if (!msg.isFromMe &&
          msg.type != MessageType.system &&
          msg.type != MessageType.messageRead &&
          !_sentReadReceipts.contains(msg.id)) {
        _sentReadReceipts.add(msg.id);
        bloc.add(ChatSendMessageRead(msg.id));
      }
    }
  }

  Future<void> _loadCaptureCapabilities() async {
    if (kIsWeb) {
      // Avoid camera permission prompts on every chat open in browsers.
      // Actual permission request happens only when user starts capture.
      if (!mounted) return;
      setState(() {
        _microphones = const [];
        _selectedMicrophoneId = null;
        _desktopCameras = const [];
        _selectedCameraName = null;
        _hasMicrophone = true;
        // Virtual camera capability for UI mode switching.
        // Actual web capture falls back to mic-only circular notes.
        _hasCamera = true;
      });
      return;
    }

    List<InputDevice> microphones = const [];
    List<CameraDeviceInfo> cameras = const [];
    try {
      microphones = await _recorder.listInputDevices();
    } catch (_) {}
    try {
      cameras = _isDesktop
          ? SgtpCamera.enumerate()
          : const []; // mobile camera list not needed here; VideoNoteRecorderPage handles it
    } catch (_) {}

    final savedMicId =
        await _settingsRepo.loadPreferredMicrophoneForNode(widget.accountId);
    final savedCameraName =
        await _settingsRepo.loadPreferredCameraForNode(widget.accountId);

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

    final hasMic = microphones.isNotEmpty;
    final hasCam =
        _isDesktop ? cameras.isNotEmpty : true; // mobile always has camera
    var videoMode = _isVideoNoteMode;
    if (!hasCam) videoMode = false;
    if (!hasMic && hasCam) videoMode = true;

    if (!mounted) return;
    setState(() {
      _microphones = microphones;
      _selectedMicrophoneId = selectedMicId;
      _desktopCameras = cameras;
      _selectedCameraName = selectedCameraName;
      _hasMicrophone = hasMic;
      _hasCamera = hasCam;
      _isVideoNoteMode = videoMode;
    });
  }

  InputDevice? _selectedMicrophoneDevice() {
    final id = _selectedMicrophoneId;
    if (id == null || id.isEmpty) return null;
    for (final mic in _microphones) {
      if (mic.id == id) return mic;
    }
    return null;
  }

  void _scrollToBottom({bool jump = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        if (jump) {
          _scrollCtrl.jumpTo(_scrollCtrl.position.maxScrollExtent);
        } else {
          _scrollCtrl.animateTo(_scrollCtrl.position.maxScrollExtent,
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOut);
        }
      }
    });
  }

  void _onScroll() {
    if (!_scrollCtrl.hasClients) return;
    if (_scrollCtrl.position.pixels <= 80) {
      _chatBloc?.add(const ChatLoadOlderHistory());
    }
  }

  /// Persist the current scroll offset for this room so we can restore it later.
  void _saveScrollPosition() {
    final roomUUID = _chatBloc?.state.roomUUID ?? '';
    if (roomUUID.isEmpty || !_scrollCtrl.hasClients) return;
    final pos = _scrollCtrl.offset;
    unawaited(
      _settingsRepo.saveChatScrollPosition(widget.accountId, roomUUID, pos),
    );
  }

  /// Restore the saved scroll position for [roomUUID], or jump to bottom if
  /// nothing was saved (first visit).
  Future<void> _tryRestoreScrollPosition(String roomUUID) async {
    if (roomUUID.isEmpty) {
      _scrollToBottom(jump: true);
      return;
    }
    try {
      final savedPos = await _settingsRepo.loadChatScrollPosition(
        widget.accountId,
        roomUUID,
      );
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_scrollCtrl.hasClients) return;
        if (savedPos != null) {
          final maxExtent = _scrollCtrl.position.maxScrollExtent;
          _scrollCtrl.jumpTo(savedPos.clamp(0.0, maxExtent));
        } else {
          _scrollCtrl.jumpTo(_scrollCtrl.position.maxScrollExtent);
        }
      });
    } catch (_) {
      _scrollToBottom(jump: true);
    }
  }

  void _sendMessage(BuildContext context) {
    final text = _messageCtrl.text.trim();
    if (text.isEmpty) return;
    final bloc = context.read<ChatBloc>();
    final reply = bloc.state.replyToMessage;
    bloc.add(ChatSendMessage(
      text,
      replyToId: reply?.id,
      replyToContent:
          reply?.content.length != null && reply!.content.length > 80
              ? '${reply.content.substring(0, 80)}…'
              : reply?.content,
      replyToSender: reply != null
          ? (bloc.state.peerNicknames[reply.senderUUID] ??
              reply.senderUUID.substring(0, 8))
          : null,
    ));
    _messageCtrl.clear();
    _focusNode.requestFocus();
    _scrollToBottom();
  }

  /// Run a media send and show upload progress bar while in flight.
  Future<void> _withProgress(Future<void> Function() fn) async {
    setState(() => _uploadProgress = 0.05);
    try {
      // Simulate progress increments while the actual upload happens
      for (var p = 0.1; p < 0.9; p += 0.15) {
        await Future.delayed(const Duration(milliseconds: 200));
        if (mounted) setState(() => _uploadProgress = p);
      }
      await fn();
    } finally {
      if (mounted) setState(() => _uploadProgress = null);
    }
  }

  Future<void> _pickAndSendMedia(BuildContext context) async {
    final choice = await showAppBottomSheet<String>(
      context,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: const Color(0xFF2C2C30),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 8),
            AppSheetTile(
                icon: Icons.image_outlined,
                label: 'Photo / GIF',
                subtitle: 'Select one or more images',
                value: 'image',
                sheetContext: context),
            AppSheetTile(
                icon: Icons.videocam_outlined,
                label: 'Video',
                subtitle: null,
                value: 'video',
                sheetContext: context),
            AppSheetTile(
                icon: Icons.radio_button_checked_outlined,
                label: 'Video note',
                subtitle: 'Circular video message',
                value: 'videonote',
                sheetContext: context),
            AppSheetTile(
                icon: Icons.content_paste_outlined,
                label: 'Paste from clipboard',
                subtitle: null,
                value: 'paste',
                sheetContext: context),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (!context.mounted) return;
    if (choice == 'image')
      await _withProgress(() => _pickAndSendImages(context));
    if (choice == 'video')
      await _withProgress(() => _pickAndSendVideo(context));
    if (choice == 'videonote')
      await _withProgress(() => _pickAndSendVideoNote(context));
    if (choice == 'paste')
      await _withProgress(() => _pasteImageFromClipboard(context));
  }

  /// Pick one OR multiple images, show caption sheet, then send text+images.
  Future<void> _pickAndSendImages(BuildContext context) async {
    final mediaSettings = await _settingsRepo.loadMediaTransferSettings();
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      withData: true,
      allowMultiple: true,
    );
    if (result == null || result.files.isEmpty) return;
    if (!context.mounted) return;

    // Build file list with mime types
    final files = result.files.where((f) => f.bytes != null).map((f) {
      final ext = f.name.split('.').last.toLowerCase();
      final mime = switch (ext) {
        'png' => 'image/png',
        'gif' => 'image/gif',
        'webp' => 'image/webp',
        _ => 'image/jpeg',
      };
      return (bytes: f.bytes!, name: f.name, mime: mime);
    }).toList();
    if (files.isEmpty) return;

    final preparedFiles = <({Uint8List bytes, String name, String mime})>[];
    for (final file in files) {
      if (mediaSettings.shouldCompressPhotos) {
        preparedFiles.add(await _prepareImageForUpload(
          bytes: file.bytes,
          name: file.name,
          mime: file.mime,
        ));
      } else {
        preparedFiles.add(file);
      }
    }

    // If there's already text in the input field OR multiple files, show caption sheet
    final existingText = _messageCtrl.text.trim();
    final String caption;

    if (preparedFiles.length > 1 || existingText.isNotEmpty) {
      // Show caption bottom sheet
      final captionResult = await _showCaptionSheet(
        this.context,
        imageCount: preparedFiles.length,
        initialCaption: existingText,
      );
      if (!mounted) return;
      if (captionResult == null) return; // user cancelled
      caption = captionResult;
    } else {
      caption = existingText;
    }

    if (!mounted) return;
    final bloc = this.context.read<ChatBloc>();

    // Send caption as text first if non-empty
    if (caption.isNotEmpty) {
      final reply = bloc.state.replyToMessage;
      bloc.add(ChatSendMessage(
        caption,
        replyToId: reply?.id,
        replyToContent: reply?.content != null && reply!.content.length > 80
            ? '${reply.content.substring(0, 80)}…'
            : reply?.content,
        replyToSender: reply != null
            ? (bloc.state.peerNicknames[reply.senderUUID] ??
                reply.senderUUID.substring(0, 8))
            : null,
      ));
      _messageCtrl.clear();
    }

    // Send all images sequentially
    for (final f in preparedFiles) {
      bloc.add(ChatSendImage(bytes: f.bytes, name: f.name, mime: f.mime));
    }
    _scrollToBottom();
  }

  /// Shows a bottom sheet with a text field for caption + send button.
  /// Returns the caption string, or null if cancelled.
  Future<String?> _showCaptionSheet(
    BuildContext context, {
    required int imageCount,
    String initialCaption = '',
  }) async {
    final ctrl = TextEditingController(text: initialCaption);
    final result = await showAppBottomSheet<String>(
      context,
      builder: (ctx) => Padding(
        padding: EdgeInsets.fromLTRB(
            16, 16, 16, MediaQuery.of(ctx).viewInsets.bottom + 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: const Color(0xFF2C2C30),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 14),
            Row(children: [
              const Icon(Icons.photo_library_outlined,
                  color: Color(0xFF8E8E93), size: 18),
              const SizedBox(width: 8),
              Text(
                imageCount == 1
                    ? '1 photo selected'
                    : '$imageCount photos selected',
                style: const TextStyle(color: Color(0xFF8E8E93), fontSize: 13),
              ),
            ]),
            const SizedBox(height: 12),
            Container(
              decoration: BoxDecoration(
                color: const Color(0xFF0A0A0C),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFF2C2C30)),
              ),
              child: TextField(
                controller: ctrl,
                autofocus: true,
                maxLines: 4,
                minLines: 1,
                style: const TextStyle(color: Color(0xFFF5F5F5), fontSize: 15),
                decoration: const InputDecoration(
                  hintText: 'Add a caption…',
                  hintStyle: TextStyle(color: Color(0xFF8E8E93)),
                  border: InputBorder.none,
                  contentPadding:
                      EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(
                child: GestureDetector(
                  onTap: () => Navigator.pop(ctx, null),
                  child: Container(
                    height: 44,
                    decoration: BoxDecoration(
                      color: const Color(0xFF1F1F24),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0xFF2C2C30)),
                    ),
                    child: const Center(
                      child: Text('Cancel',
                          style: TextStyle(
                              color: Color(0xFF8E8E93),
                              fontSize: 15,
                              fontWeight: FontWeight.w500)),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: GestureDetector(
                  onTap: () => Navigator.pop(ctx, ctrl.text.trim()),
                  child: Container(
                    height: 44,
                    decoration: BoxDecoration(
                      color: const Color(0xFF0A84FF),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Center(
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.send, color: Colors.white, size: 16),
                          const SizedBox(width: 6),
                          Text(
                            imageCount == 1 ? 'Send' : 'Send $imageCount',
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 15,
                                fontWeight: FontWeight.w600),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ]),
          ],
        ),
      ),
    );
    ctrl.dispose();
    return result;
  }

  Future<void> _pickAndSendVideoNote(BuildContext context) async {
    final picked = await _pickVideoFile();
    if (picked == null) return;
    final xFile = picked.$1;
    final ext = picked.$2;
    if (!_videoExtensions.contains(ext)) {
      if (context.mounted) _showSnack(context, 'Unsupported format: .$ext');
      return;
    }
    if (!context.mounted) return;
    context
        .read<ChatBloc>()
        .add(ChatSendVideoNoteFile(xFile: xFile, mime: _videoMimeForExt(ext)));
    _scrollToBottom();
  }

  Future<void> _pickAndSendVideo(BuildContext context) async {
    final mediaSettings = await _settingsRepo.loadMediaTransferSettings();
    final picked = await _pickVideoFile();
    if (picked == null) return;
    final xFile = picked.$1;
    final ext = picked.$2;
    if (!_videoExtensions.contains(ext)) {
      if (context.mounted) _showSnack(context, 'Unsupported format: .$ext');
      return;
    }
    final mime = _videoMimeForExt(ext);
    if (!context.mounted) return;
    if (mediaSettings.shouldCompressVideos) {
      _showSnack(
          context, 'Video compression is not available yet in this build');
    }
    context
        .read<ChatBloc>()
        .add(ChatSendVideo(xFile: xFile, name: xFile.name, mime: mime));
    _scrollToBottom();
  }

  /// Desktop = Windows / macOS / Linux. Mobile = Android / iOS.
  bool get _isDesktop =>
      !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);

  Future<void> _toggleRecording(BuildContext context) async {
    if (_isRecording) {
      await _stopAndSend(context);
    } else {
      await _startRecording(context);
    }
  }

  /// Toggle between voice and video-note mode (mobile short tap).
  void _toggleMode() {
    if (_isRecording) return; // can't switch while recording
    if (_hasMicrophone && _hasCamera) {
      setState(() => _isVideoNoteMode = !_isVideoNoteMode);
      return;
    }
    if (_hasCamera && !_hasMicrophone) {
      setState(() => _isVideoNoteMode = true);
      return;
    }
    if (_hasMicrophone && !_hasCamera) {
      setState(() => _isVideoNoteMode = false);
    }
  }

  /// Start hold-recording (mobile long-press down).
  Future<void> _startHoldRecording(BuildContext context) async {
    if (_isRecording) return;
    setState(() => _isHoldRecording = true);
    await _startRecording(context);
  }

  /// In video-note mode: open camera recorder. In voice mode: start hold-recording.
  Future<void> _startHoldRecordingOrCamera(BuildContext context) async {
    final useCamera = _isVideoNoteMode && _hasCamera;
    if (useCamera) {
      // Open full-screen camera recorder; get recorded file + detected MIME.
      CameraDeviceInfo? preferredDesktop;
      if (_isDesktop) {
        for (final cam in _desktopCameras) {
          if (cam.id == _selectedCameraName) {
            preferredDesktop = cam;
            break;
          }
        }
      }
      final capture = await Navigator.of(context).push<VideoNoteCaptureResult?>(
        MaterialPageRoute(
          builder: (_) => VideoNoteRecorderPage(
            accountId: widget.accountId,
            preferredCameraName: preferredDesktop?.id ?? _selectedCameraName,
          ),
          fullscreenDialog: true,
        ),
      );
      if (capture != null && context.mounted) {
        context.read<ChatBloc>().add(ChatSendVideoNoteFile(
              xFile: capture.xFile,
              mime: capture.mime,
              metadata: capture.metadata,
              isFrontCameraSource: true,
            ));
        _scrollToBottom();
      }
    } else {
      if (!_hasMicrophone) return;
      await _startHoldRecording(context);
    }
  }

  /// Stop hold-recording and send (mobile long-press up).
  Future<void> _stopHoldRecording(BuildContext context) async {
    if (!_isHoldRecording) return;
    setState(() => _isHoldRecording = false);
    await _stopAndSend(context);
  }

  Future<void> _startRecording(BuildContext context) async {
    if (!_hasMicrophone) {
      if (context.mounted) {
        _showSnack(context, 'No microphone available');
      }
      return;
    }
    if (!await _recorder.hasPermission()) {
      if (context.mounted) _showSnack(context, 'No microphone permission');
      return;
    }
    try {
      if (kIsWeb) {
        // record_web ignores filesystem path and returns a blob URL on stop.
        _recordingPath = 'voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
      } else {
        _recordingPath = await _mediaStorage.createRecordingPath(
          accountId: widget.accountId,
          prefix: 'voice',
          extension: 'm4a',
        );
      }
      await _recorder.start(
          RecordConfig(
              encoder: AudioEncoder.aacLc,
              bitRate: 128000,
              sampleRate: 44100,
              device: _selectedMicrophoneDevice()),
          path: _recordingPath!);
      setState(() => _isRecording = true);
    } catch (e) {
      if (context.mounted) _showSnack(context, 'Record error: $e');
    }
  }

  Future<void> _stopAndSend(BuildContext context) async {
    try {
      final path = await _recorder.stop();
      setState(() {
        _isRecording = false;
        _isHoldRecording = false;
      });
      if (path == null) return;
      final bytes = await _readRecordingBytes(path);
      if (bytes == null || bytes.isEmpty) return;
      final recordedMime = kIsWeb ? 'audio/mp4' : 'audio/m4a';
      if (context.mounted) {
        if (_isVideoNoteMode) {
          // Video note (circle): audio-only fallback recorded as m4a,
          // sent as video_note type so the receiver renders it as a circle bubble.
          context
              .read<ChatBloc>()
              .add(ChatSendVideoNote(bytes: bytes, mime: recordedMime));
        } else {
          context
              .read<ChatBloc>()
              .add(ChatSendVoice(bytes: bytes, mime: recordedMime));
        }
        _scrollToBottom();
      }
      if (!kIsWeb) {
        try {
          await File(path).delete();
        } catch (_) {}
      }
    } catch (e) {
      setState(() {
        _isRecording = false;
        _isHoldRecording = false;
      });
      if (context.mounted) _showSnack(context, 'Error: $e');
    }
  }

  Future<Uint8List?> _readRecordingBytes(String path) async {
    if (kIsWeb) {
      try {
        final bytes = await XFile(path).readAsBytes();
        return bytes.isEmpty ? null : bytes;
      } catch (_) {
        return null;
      }
    }
    final file = File(path);
    if (!file.existsSync() || file.lengthSync() == 0) return null;
    return file.readAsBytes();
  }

  String _videoMimeForExt(String ext) => switch (ext.toLowerCase()) {
        'mp4' => 'video/mp4',
        'mov' => 'video/quicktime',
        'webm' => 'video/webm',
        'avi' => 'video/x-msvideo',
        'mkv' => 'video/x-matroska',
        'm4v' => 'video/x-m4v',
        '3gp' => 'video/3gpp',
        _ => 'video/mp4',
      };

  String _imageExtensionForMime(String mime) => switch (mime.toLowerCase()) {
        'image/jpeg' => 'jpg',
        'image/jpg' => 'jpg',
        'image/png' => 'png',
        'image/webp' => 'webp',
        'image/gif' => 'gif',
        'image/bmp' => 'bmp',
        'image/tiff' => 'tiff',
        _ => 'png',
      };

  Future<void> _pasteImageFromClipboard(
    BuildContext context, {
    Uint8List? preloadedBytes,
  }) async {
    try {
      final mediaSettings = await _settingsRepo.loadMediaTransferSettings();
      final imageBytes = preloadedBytes ?? await Pasteboard.image;
      if (!mounted) return;
      if (imageBytes == null) {
        _showSnack(this.context, 'No image in clipboard');
        return;
      }
      if (!mounted) return;

      // Show preview sheet — let user confirm or cancel before sending.
      final confirmed = await showAppBottomSheet<bool>(
        context,
        builder: (ctx) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 24, 20, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Send image?',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 280),
                    child: Image.memory(imageBytes, fit: BoxFit.contain),
                  ),
                ),
                const SizedBox(height: 16),
                Row(children: [
                  Expanded(
                    child: AppSheetButton(
                      label: 'Cancel',
                      secondary: true,
                      onTap: () => Navigator.pop(ctx, false),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: AppSheetButton(
                      label: 'Send',
                      onTap: () => Navigator.pop(ctx, true),
                    ),
                  ),
                ]),
              ],
            ),
          ),
        ),
      );
      if (confirmed != true || !context.mounted) return;

      final prepared = mediaSettings.shouldCompressPhotos
          ? await _prepareImageForUpload(
              bytes: imageBytes,
              name: 'clipboard_${DateTime.now().millisecondsSinceEpoch}.png',
              mime: 'image/png',
            )
          : (
              bytes: imageBytes,
              name: 'clipboard_${DateTime.now().millisecondsSinceEpoch}.png',
              mime: 'image/png',
            );

      if (!mounted) return;
      this.context.read<ChatBloc>().add(ChatSendImage(
            bytes: prepared.bytes,
            name: prepared.name,
            mime: prepared.mime,
          ));
      _scrollToBottom();
    } catch (e) {
      if (!mounted) return;
      _showSnack(this.context, 'Failed to paste image: $e');
    }
  }

  Future<void> _handleKeyboardInsertedContent(
    KeyboardInsertedContent content,
  ) async {
    if (!content.mimeType.toLowerCase().startsWith('image/')) {
      return;
    }
    try {
      final bytes = content.hasData
          ? content.data
          : await AndroidKeyboardContentLoader.loadBytes(content.uri);
      if (!mounted || bytes == null || bytes.isEmpty) {
        return;
      }

      final mediaSettings = await _settingsRepo.loadMediaTransferSettings();
      final now = DateTime.now().millisecondsSinceEpoch;
      final name = 'keyboard_$now.${_imageExtensionForMime(content.mimeType)}';
      final prepared = mediaSettings.shouldCompressPhotos
          ? await _prepareImageForUpload(
              bytes: bytes,
              name: name,
              mime: content.mimeType,
            )
          : (
              bytes: bytes,
              name: name,
              mime: content.mimeType,
            );

      if (!mounted) return;
      this.context.read<ChatBloc>().add(
            ChatSendImage(
              bytes: prepared.bytes,
              name: prepared.name,
              mime: prepared.mime,
            ),
          );
      _scrollToBottom();
    } catch (e) {
      if (!mounted) return;
      _showSnack(this.context, 'Failed to insert image: $e');
    }
  }

  Future<({Uint8List bytes, String name, String mime})> _prepareImageForUpload({
    required Uint8List bytes,
    required String name,
    required String mime,
  }) async {
    if (mime == 'image/gif') {
      return (bytes: bytes, name: name, mime: mime);
    }

    final decoded = img.decodeImage(bytes);
    if (decoded == null) {
      return (bytes: bytes, name: name, mime: mime);
    }

    img.Image processed = decoded;
    final longestSide =
        processed.width > processed.height ? processed.width : processed.height;
    if (longestSide > _maxUploadImageDimension) {
      processed = img.copyResize(
        processed,
        width: processed.width >= processed.height
            ? _maxUploadImageDimension
            : null,
        height: processed.height > processed.width
            ? _maxUploadImageDimension
            : null,
        interpolation: img.Interpolation.average,
      );
    }

    final hasAlpha = processed.hasAlpha;
    if (hasAlpha) {
      final encodedPng = Uint8List.fromList(img.encodePng(processed, level: 6));
      if (encodedPng.length < bytes.length ||
          bytes.length > _targetUploadImageBytes) {
        final pngName = name.replaceAll(RegExp(r'\.[^.]+$'), '.png');
        return (bytes: encodedPng, name: pngName, mime: 'image/png');
      }
      return (bytes: bytes, name: name, mime: mime);
    }

    final encodedJpg =
        Uint8List.fromList(img.encodeJpg(processed, quality: 84));
    if (encodedJpg.length < bytes.length ||
        bytes.length > _targetUploadImageBytes) {
      final jpgName = name.replaceAll(RegExp(r'\.[^.]+$'), '.jpg');
      return (bytes: encodedJpg, name: jpgName, mime: 'image/jpeg');
    }

    return (bytes: bytes, name: name, mime: mime);
  }

  void _showSnack(BuildContext context, String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(text),
      behavior: SnackBarBehavior.floating,
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 80),
    ));
  }

  Future<(XFile, String)?> _pickVideoFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.video,
      withData: kIsWeb,
    );
    if (result == null) return null;

    XFile? xFile = result.xFiles.isNotEmpty ? result.xFiles.first : null;

    if (kIsWeb && xFile == null && result.files.isNotEmpty) {
      final file = result.files.first;
      final bytes = file.bytes;
      if (bytes != null && bytes.isNotEmpty) {
        xFile = XFile.fromData(
          bytes,
          name: file.name,
          mimeType: file.extension != null
              ? _videoMimeForExt(file.extension!.toLowerCase())
              : 'video/mp4',
        );
      }
    }

    if (xFile == null) return null;

    final ext = _videoExtFromName(xFile.name);
    return (xFile, ext);
  }

  String _videoExtFromName(String name) {
    final dot = name.lastIndexOf('.');
    if (dot < 0 || dot >= name.length - 1) return '';
    return name.substring(dot + 1).toLowerCase();
  }

  Future<void> _handlePasteShortcut(BuildContext context) async {
    if (!mounted) return;
    try {
      final imageBytes = await Pasteboard.image;
      if (!mounted || imageBytes == null) return;
      await _pasteImageFromClipboard(this.context, preloadedBytes: imageBytes);
    } catch (_) {
      // Let native text paste continue silently when image clipboard is blocked.
    }
  }

  /// Show bottom sheet to edit chat name and avatar.
  void _showEditMetadataDialog(BuildContext context, ChatState state) {
    final nameCtrl = TextEditingController(text: state.chatName);
    Uint8List? newAvatar = state.chatAvatarBytes;

    showAppBottomSheet<void>(
      context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => SafeArea(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
                20, 24, 20, MediaQuery.of(ctx).viewInsets.bottom + 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Edit Chat',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 20),
                GestureDetector(
                  onTap: () async {
                    final picker = ImagePicker();
                    final file = await picker.pickImage(
                        source: ImageSource.gallery,
                        maxWidth: 256,
                        maxHeight: 256,
                        imageQuality: 80);
                    if (file == null) return;
                    final bytes = await file.readAsBytes();
                    setS(() => newAvatar = bytes);
                  },
                  child: CircleAvatar(
                    radius: 44,
                    backgroundImage:
                        newAvatar != null ? MemoryImage(newAvatar!) : null,
                    child: newAvatar == null
                        ? const Icon(Icons.camera_alt, size: 32)
                        : null,
                  ),
                ),
                if (newAvatar != null) ...[
                  const SizedBox(height: 4),
                  TextButton.icon(
                    onPressed: () => setS(() => newAvatar = null),
                    icon: const Icon(Icons.delete_outline, size: 16),
                    label: const Text('Remove avatar'),
                  ),
                ],
                const SizedBox(height: 16),
                TextField(
                  controller: nameCtrl,
                  style: const TextStyle(color: AppColors.textPrimary),
                  decoration: InputDecoration(
                    labelText: 'Chat Name',
                    labelStyle: const TextStyle(color: AppColors.textSecondary),
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
                  maxLength: 100,
                ),
                const SizedBox(height: 16),
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
                      label: 'Save',
                      onTap: () {
                        final name = nameCtrl.text.trim();
                        if (name.isEmpty) return;
                        context.read<ChatBloc>().add(ChatUpdateMetadata(
                            name: name, avatarBytes: newAvatar));
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
    ).whenComplete(nameCtrl.dispose);
  }

  @override
  Widget build(BuildContext context) {
    _chatBloc ??= context.read<ChatBloc>();
    return BlocConsumer<ChatBloc, ChatState>(
      listener: (context, state) {
        // Always cache the bloc via context.read — it is always valid inside
        // a BlocConsumer listener (unlike _chatBloc which starts as null).
        _chatBloc ??= context.read<ChatBloc>();
        final bloc = context.read<ChatBloc>();

        if (state.messages.isNotEmpty) {
          final prevCount = _lastMessageCount;
          final newCount = state.messages.length;
          if (prevCount == 0 && !_scrollRestored) {
            // First load — restore saved position or jump to bottom
            _scrollRestored = true;
            final roomUUID = state.roomUUID;
            if (roomUUID != _lastScrollRoomUUID) {
              _lastScrollRoomUUID = roomUUID;
            }
            _tryRestoreScrollPosition(roomUUID);
          } else if (newCount > prevCount) {
            final newest = state.messages.last;
            if (newest.isFromMe) {
              // Own message — always scroll to bottom
              _scrollToBottom();
            } else {
              // Incoming message — only scroll if already near bottom
              if (_scrollCtrl.hasClients) {
                final pos = _scrollCtrl.position;
                final nearBottom = pos.maxScrollExtent - pos.pixels < 120;
                if (nearBottom) _scrollToBottom();
              }
            }
          }
          _lastMessageCount = newCount;
        }
        if (state.status == ChatStatus.ready && !_infoShown) {
          _infoShown = true;
        }

        // ── Read receipts + background notifications ─────────────────────
        for (final msg in state.messages) {
          if (msg.isFromMe) continue;
          if (msg.type == MessageType.system) continue;
          if (msg.type == MessageType.messageRead) continue;
          if (_sentReadReceipts.contains(msg.id)) continue;

          if (_isPageVisible) {
            // Chat window is open → send read receipt immediately.
            // Use context.read<ChatBloc>() (always non-null here) so receipts
            // are never dropped on the first listener call when _chatBloc
            // was still null.
            _sentReadReceipts.add(msg.id);
            bloc.add(ChatSendMessageRead(msg.id));
          } else {
            // App in background → show notification so the user can read it.
            final senderLabel = state.peerNicknames[msg.senderUUID] ??
                state.peerNicknamesHistory[msg.senderUUID] ??
                (msg.senderUUID.length >= 8
                    ? msg.senderUUID.substring(0, 8)
                    : msg.senderUUID);
            final body = msg.type == MessageType.text
                ? msg.content
                : '[${msg.type.name}]';
            // Pass sender avatar if available — shown as icon on Android
            // and as attachment thumbnail on iOS/macOS.
            final avatar =
                state.peerAvatars[msg.senderUUID] ?? msg.senderAvatarBytes;
            NotificationService.showMessage(
              sender: senderLabel,
              body: body,
              messageId: msg.id,
              avatarBytes: avatar,
            );
          }
        }
        // Don't auto-pop — user can reconnect from the chat page
      },
      builder: (context, state) {
        return PopScope(
          canPop: false,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) {
              _saveScrollPosition();
              if (_isRecording) _recorder.stop();
              Navigator.of(context).pop();
            }
          },
          child: Focus(
            autofocus: true,
            onKeyEvent: (_, event) {
              if (event is! KeyDownEvent) return KeyEventResult.ignored;
              final isPaste = event.logicalKey == LogicalKeyboardKey.keyV &&
                  (HardwareKeyboard.instance.isControlPressed ||
                      HardwareKeyboard.instance.isMetaPressed);
              if (!isPaste) return KeyEventResult.ignored;
              unawaited(_handlePasteShortcut(context));
              // Keep default text paste behavior in focused TextField.
              return KeyEventResult.ignored;
            },
            child: Scaffold(
              backgroundColor: const Color(0xFF0A0A0C),
              appBar: _buildAppBar(context, state),
              body: Column(
                children: [
                  _buildStatusBanner(context, state),
                  Expanded(child: _buildMessageList(state)),
                  _buildInputBar(context, state),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  PreferredSizeWidget _buildAppBar(BuildContext context, ChatState state) {
    final dmDebug = _dmDebugLabel(state);
    return PreferredSize(
      preferredSize: const Size.fromHeight(62),
      child: ClipRect(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
          child: Container(
            decoration: const BoxDecoration(
              color: Color(0xD80A0A0C),
              border: Border(
                bottom: BorderSide(color: Color(0xFF2C2C30)),
              ),
            ),
            child: SafeArea(
              bottom: false,
              child: SizedBox(
                height: 62,
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
                  child: Row(
                    children: [
                      // Back button
                      IconButton(
                        icon: const Icon(Icons.arrow_back, size: 24),
                        color: const Color(0xFFF5F5F5),
                        onPressed: () {
                          if (_isRecording) _recorder.stop();
                          if (Navigator.of(context).canPop())
                            Navigator.of(context).pop();
                        },
                        padding: const EdgeInsets.all(4),
                        visualDensity: VisualDensity.compact,
                      ),

                      const SizedBox(width: 4),

                      // Avatar
                      GestureDetector(
                        onTap: state.status == ChatStatus.ready
                            ? () => _showEditMetadataDialog(context, state)
                            : null,
                        child: RoomAvatar(
                          avatarBytes: state.chatAvatarBytes,
                          fallbackName: state.chatName,
                          size: 38,
                        ),
                      ),

                      const SizedBox(width: 10),

                      // Room name + peer count
                      Expanded(
                        child: GestureDetector(
                          onTap: state.status == ChatStatus.ready
                              ? () => _showEditMetadataDialog(context, state)
                              : null,
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                state.chatName,
                                style: const TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                  color: Color(0xFFF5F5F5),
                                  letterSpacing: -0.2,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                              Text(
                                state.peerUUIDs.isEmpty
                                    ? 'No peers'
                                    : '${state.peerUUIDs.length} peer${state.peerUUIDs.length == 1 ? '' : 's'}',
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: Color(0xFF8E8E93),
                                ),
                              ),
                              if (dmDebug != null)
                                Text(
                                  dmDebug,
                                  style: const TextStyle(
                                    fontSize: 11,
                                    color: Color(0xFF8E8E93),
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                            ],
                          ),
                        ),
                      ),

                      // Action buttons
                      if (state.status == ChatStatus.ready)
                        IconButton(
                          icon: Badge(
                            label: Text('${state.peerUUIDs.length}'),
                            isLabelVisible: state.peerUUIDs.isNotEmpty,
                            child: const Icon(Icons.group_outlined, size: 22),
                          ),
                          color: const Color(0xFF8E8E93),
                          onPressed: () => _showPeersSheet(context, state),
                          padding: const EdgeInsets.all(4),
                          visualDensity: VisualDensity.compact,
                        ),
                      PopupMenuButton<int>(
                        icon: const Icon(Icons.more_vert,
                            size: 22, color: Color(0xFF8E8E93)),
                        padding: const EdgeInsets.all(4),
                        onSelected: (action) {
                          if (action == 0) {
                            _showEditMetadataDialog(context, state);
                          }
                        },
                        itemBuilder: (_) => [
                          PopupMenuItem(
                            value: 0,
                            enabled: state.status == ChatStatus.ready,
                            child: const ListTile(
                              leading: Icon(Icons.edit_outlined),
                              title: Text('Edit chat'),
                              contentPadding: EdgeInsets.zero,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  String? _dmDebugLabel(ChatState state) {
    if (!kDebugMode) return null;
    final pubs = state.peerPublicKeys.values.toList(growable: false);
    final isDirect = state.isDirectChat;
    final chosenPub = pubs.length == 1 ? pubs.first.toLowerCase() : null;
    final myPub = state.myPublicKeyHex.toLowerCase();
    final source = !isDirect
        ? 'n/a'
        : (chosenPub == null
            ? 'pending'
            : (chosenPub == myPub ? 'self' : 'peer'));
    final hasAvatar =
        state.chatAvatarBytes != null && state.chatAvatarBytes!.isNotEmpty;
    return 'dbg directFlag=$isDirect pubs=${pubs.length} source=$source avatar=${hasAvatar ? 'set' : 'null'}';
  }

  Widget _buildStatusBanner(BuildContext context, ChatState state) {
    switch (state.status) {
      case ChatStatus.connecting:
        return _statusBanner(
          text: 'Connecting to server…',
          color: const Color(0xFF0A84FF),
          bgColor: const Color(0x1A0A84FF),
          borderColor: const Color(0x330A84FF),
          withSpinner: true,
        );
      case ChatStatus.handshaking:
        return _statusBanner(
          text: 'Performing handshake…',
          color: const Color(0xFFFF9F0A),
          bgColor: const Color(0x26FF9F0A),
          borderColor: const Color(0x33FF9F0A),
          withSpinner: true,
        );
      case ChatStatus.error:
        return _statusBanner(
          text: state.errorMessage ?? 'Error',
          color: const Color(0xFFFF3B30),
          bgColor: const Color(0x26FF3B30),
          borderColor: const Color(0x33FF3B30),
          withSpinner: false,
        );
      case ChatStatus.ready:
        return const SizedBox.shrink();
      case ChatStatus.disconnected:
        return _statusBanner(
          text: 'Reconnecting…',
          color: const Color(0xFF8E8E93),
          bgColor: const Color(0x26636366),
          borderColor: const Color(0x33636366),
          withSpinner: true,
        );
    }
  }

  Widget _statusBanner({
    required String text,
    required Color color,
    required Color bgColor,
    required Color borderColor,
    required bool withSpinner,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: bgColor,
        border: Border(bottom: BorderSide(color: borderColor)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (withSpinner) ...[
            SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: color,
              ),
            ),
            const SizedBox(width: 8),
          ],
          Expanded(
            child: Text(
              text,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: color,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMessageList(ChatState state) {
    if (state.messages.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.chat_bubble_outline,
                size: 64, color: Color(0xFF636366)),
            const SizedBox(height: 16),
            Text(
              state.status == ChatStatus.ready
                  ? 'No messages yet. Say hello!'
                  : 'No local history yet.',
              style: const TextStyle(fontSize: 16, color: Color(0xFF8E8E93)),
            ),
          ]),
        ),
      );
    }
    return ListView.builder(
      controller: _scrollCtrl,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      itemCount: state.messages.length + (state.isLoadingHistory ? 1 : 0),
      itemBuilder: (context, index) {
        if (state.isLoadingHistory && index == 0) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Center(
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          );
        }
        final msgIndex = index - (state.isLoadingHistory ? 1 : 0);
        final msg = state.messages[msgIndex];
        final isInteractable = msg.type != MessageType.system &&
            msg.type != MessageType.messageRead;

        Widget bubble = MessageBubble(
          accountId: widget.accountId,
          message: msg,
          peerNicknames: {
            ...state.peerNicknames,
            ...state.peerNicknamesHistory,
            ...state.nicknames,
          },
          myUUID: state.myUUID,
          peerAvatars: state.peerAvatars,
          userAvatarBytes: state.userAvatarBytes,
          readReceipts: state.readReceipts,
          onReply: isInteractable
              ? () {
                  context.read<ChatBloc>().add(ChatSetReply(msg));
                }
              : null,
          onReact: isInteractable
              ? (emoji) {
                  context
                      .read<ChatBloc>()
                      .add(ChatToggleReaction(messageId: msg.id, emoji: emoji));
                }
              : null,
          quickEmojis: _quickEmojis,
        );

        // Swipe right to reply (respects user interaction pref)
        if (isInteractable && InteractionPrefs.swipeToReply) {
          bubble = Dismissible(
            key: ValueKey('swipe_${msg.id}'),
            direction: DismissDirection.startToEnd,
            confirmDismiss: (_) async {
              context.read<ChatBloc>().add(ChatSetReply(msg));
              return false; // don't actually dismiss
            },
            background: Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.only(left: 16),
                child: Icon(Icons.reply_rounded,
                    color: Theme.of(context).colorScheme.primary),
              ),
            ),
            child: bubble,
          );
        }

        return bubble;
      },
    );
  }

  Widget _buildInputBar(BuildContext context, ChatState state) {
    final canSend = state.status == ChatStatus.ready;
    final reply = state.replyToMessage;

    return SafeArea(
      child: Container(
        decoration: const BoxDecoration(
          color: Color(0xF2141417),
          border: Border(top: BorderSide(color: Color(0xFF2C2C30))),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // ── Upload progress ───────────────────────────────────────────
            if (_uploadProgress != null)
              LinearProgressIndicator(
                value: _uploadProgress,
                minHeight: 2,
                backgroundColor: const Color(0xFF1F1F24),
                color: const Color(0xFF0A84FF),
              ),

            // ── Recording indicator ───────────────────────────────────────
            if (_isRecording)
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                decoration: const BoxDecoration(
                  color: Color(0x26FF3B30),
                  border: Border(bottom: BorderSide(color: Color(0x33FF3B30))),
                ),
                child: Row(children: [
                  const Icon(Icons.fiber_manual_record,
                      size: 10, color: Color(0xFFFF3B30)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _isVideoNoteMode
                          ? 'Recording video note… tap ■ to send'
                          : 'Recording… tap ■ to send',
                      style: const TextStyle(
                          fontSize: 13, color: Color(0xFFFF3B30)),
                    ),
                  ),
                  TextButton(
                    onPressed: () async {
                      await _recorder.stop();
                      setState(() => _isRecording = false);
                    },
                    style: TextButton.styleFrom(
                        foregroundColor: const Color(0xFF8E8E93)),
                    child: const Text('Cancel'),
                  ),
                ]),
              ),

            // ── Reply preview ─────────────────────────────────────────────
            if (reply != null)
              Container(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Row(children: [
                  Container(
                    width: 3,
                    height: 36,
                    decoration: BoxDecoration(
                      color: const Color(0xFF0A84FF),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          reply.isFromMe
                              ? 'You'
                              : (state.peerNicknames[reply.senderUUID] ??
                                  reply.senderUUID.substring(0, 8)),
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF0A84FF),
                          ),
                        ),
                        Text(
                          reply.type == MessageType.text
                              ? reply.content
                              : '[${reply.type.name}]',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 13, color: Color(0xFF8E8E93)),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close,
                        size: 18, color: Color(0xFF8E8E93)),
                    onPressed: () =>
                        context.read<ChatBloc>().add(const ChatClearReply()),
                    padding: EdgeInsets.zero,
                    visualDensity: VisualDensity.compact,
                  ),
                ]),
              ),

            // ── Input row ─────────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  // Attach button
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: GestureDetector(
                      onTap: canSend && _uploadProgress == null
                          ? () => _pickAndSendMedia(context)
                          : null,
                      child: Padding(
                        padding: const EdgeInsets.all(4),
                        child: Transform.rotate(
                          angle: -0.785, // -45 degrees
                          child: Icon(
                            Icons.attach_file_outlined,
                            size: 24,
                            color: canSend
                                ? const Color(0xFF8E8E93)
                                : const Color(0xFF3A3A3E),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),

                  // Text input
                  Expanded(
                    child: Container(
                      decoration: BoxDecoration(
                        color: const Color(0xFF0A0A0C),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: const Color(0xFF2C2C30)),
                      ),
                      child: TextField(
                        controller: _messageCtrl,
                        focusNode: _focusNode,
                        enabled: canSend && !_isRecording,
                        contentInsertionConfiguration:
                            ContentInsertionConfiguration(
                          onContentInserted: (content) {
                            unawaited(_handleKeyboardInsertedContent(content));
                          },
                        ),
                        decoration: InputDecoration(
                          hintText: _isRecording
                              ? 'Recording…'
                              : canSend
                                  ? 'Message…'
                                  : 'Waiting…',
                          hintStyle: const TextStyle(
                              color: Color(0xFF8E8E93), fontSize: 15),
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          disabledBorder: InputBorder.none,
                          fillColor: Colors.transparent,
                          filled: true,
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 10),
                        ),
                        style: const TextStyle(
                            color: Color(0xFFF5F5F5), fontSize: 15),
                        minLines: 1,
                        maxLines: 5,
                        textInputAction: TextInputAction.send,
                        onSubmitted: canSend
                            ? (value) {
                                if (value.trim().isEmpty) {
                                  _focusNode.requestFocus();
                                  return;
                                }
                                _sendMessage(context);
                              }
                            : null,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),

                  // Send / capture button
                  if (_hasText || (_isRecording && _isDesktop))
                    GestureDetector(
                      onTap: canSend && !_isRecording
                          ? () => _sendMessage(context)
                          : canSend && _isRecording
                              ? () => _stopAndSend(context)
                              : null,
                      child: Container(
                        width: 40,
                        height: 40,
                        decoration: const BoxDecoration(
                          color: Color(0xFF0A84FF),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.send,
                            color: Colors.white, size: 22),
                      ),
                    )
                  else
                    Builder(builder: (_) {
                      final canCapture = _hasMicrophone || _hasCamera;
                      if (!canCapture) {
                        return GestureDetector(
                          onTap: canSend ? () => _sendMessage(context) : null,
                          child: Container(
                            width: 40,
                            height: 40,
                            decoration: BoxDecoration(
                              color: canSend
                                  ? const Color(0xFF0A84FF)
                                  : const Color(0xFF1F1F24),
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(Icons.send,
                                color: Colors.white, size: 22),
                          ),
                        );
                      }
                      if (_isDesktop && _hasMicrophone && !_hasCamera) {
                        return GestureDetector(
                          onTap:
                              canSend ? () => _toggleRecording(context) : null,
                          child: Container(
                            width: 40,
                            height: 40,
                            decoration: BoxDecoration(
                              color: _isRecording
                                  ? const Color(0xFFFF3B30)
                                  : const Color(0xFF1F1F24),
                              shape: BoxShape.circle,
                              border:
                                  Border.all(color: const Color(0xFF2C2C30)),
                            ),
                            child: Icon(
                              _isRecording
                                  ? Icons.stop_rounded
                                  : Icons.mic_rounded,
                              color: _isRecording
                                  ? Colors.white
                                  : const Color(0xFFF5F5F5),
                              size: 22,
                            ),
                          ),
                        );
                      }
                      return _MobileModeButton(
                        isVideoNoteMode: _isVideoNoteMode,
                        isRecording: _isRecording,
                        onTap: _toggleMode,
                        onHoldStart: canSend && !_isRecording
                            ? () => _startHoldRecordingOrCamera(context)
                            : null,
                        onHoldEnd:
                            canSend ? () => _stopHoldRecording(context) : null,
                        onTapStop: canSend && _isRecording
                            ? () => _stopAndSend(context)
                            : null,
                      );
                    }),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showPeersSheet(BuildContext context, ChatState state) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.45,
        minChildSize: 0.25,
        maxChildSize: 0.88,
        builder: (sheetCtx, scrollCtrl) => Container(
          decoration: const BoxDecoration(
            color: Color(0xFF141417),
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Drag handle
              Padding(
                padding: const EdgeInsets.only(top: 12, bottom: 4),
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: const Color(0xFF2C2C30),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                child: Row(children: [
                  Text('Connected peers',
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(width: 8),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0A84FF).withAlpha(40),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      '${state.peerUUIDs.length}',
                      style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF0A84FF)),
                    ),
                  ),
                ]),
              ),
              const Divider(height: 1, color: Color(0xFF2C2C30)),
              Flexible(
                child: state.peerUUIDs.isEmpty
                    ? const Center(
                        child: Padding(
                          padding: EdgeInsets.symmetric(vertical: 32),
                          child: Text('No peers connected',
                              style: TextStyle(color: Color(0xFF8E8E93))),
                        ),
                      )
                    : ListView.separated(
                        controller: scrollCtrl,
                        padding: const EdgeInsets.only(bottom: 32),
                        itemCount: state.peerUUIDs.length,
                        separatorBuilder: (_, __) => const Divider(
                          height: 1,
                          color: Color(0xFF2C2C30),
                          indent: 72,
                        ),
                        itemBuilder: (_, i) {
                          final uuid = state.peerUUIDs[i];
                          final nick = state.peerNicknames[uuid];
                          final displayName = nick ?? uuid.substring(0, 8);
                          final avatarBytes = state.peerAvatars[uuid];
                          final initial = displayName.isNotEmpty
                              ? displayName[0].toUpperCase()
                              : '?';
                          return ListTile(
                            contentPadding: const EdgeInsets.symmetric(
                                horizontal: 20, vertical: 4),
                            leading: Container(
                              width: 40,
                              height: 40,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: const Color(0xFF1F1F24),
                                border:
                                    Border.all(color: const Color(0xFF2C2C30)),
                              ),
                              child: ClipOval(
                                child: avatarBytes != null
                                    ? Image.memory(avatarBytes,
                                        fit: BoxFit.cover)
                                    : Center(
                                        child: Text(initial,
                                            style: const TextStyle(
                                                fontSize: 15,
                                                fontWeight: FontWeight.bold,
                                                color: Color(0xFFF5F5F5))),
                                      ),
                              ),
                            ),
                            title: Text(
                              nick ?? '${uuid.substring(0, 8)}…',
                              style: const TextStyle(
                                  color: Color(0xFFF5F5F5),
                                  fontSize: 15,
                                  fontWeight: FontWeight.w500),
                            ),
                            subtitle: nick != null
                                ? Text(
                                    '${uuid.substring(0, 8)}…',
                                    style: const TextStyle(
                                        fontFamily: 'monospace',
                                        fontSize: 11,
                                        color: Color(0xFF8E8E93)),
                                  )
                                : null,
                            trailing: IconButton(
                              icon: const Icon(Icons.copy,
                                  size: 18, color: Color(0xFF8E8E93)),
                              tooltip: 'Copy UUID',
                              onPressed: () {
                                Clipboard.setData(ClipboardData(text: uuid));
                                Navigator.pop(context);
                                _showSnack(context, 'UUID copied');
                              },
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
              ),
  );
  }

}

// ─────────────────────────────────────────────────────────────────────────────
// Mobile mode button (mic ↔ video-note) — single button, tap = swap, hold = record
// ─────────────────────────────────────────────────────────────────────────────

class _MobileModeButton extends StatelessWidget {
  final bool isVideoNoteMode;
  final bool isRecording;
  final VoidCallback onTap;
  final VoidCallback? onHoldStart;
  final VoidCallback? onHoldEnd;
  final VoidCallback? onTapStop;

  const _MobileModeButton({
    required this.isVideoNoteMode,
    required this.isRecording,
    required this.onTap,
    this.onHoldStart,
    this.onHoldEnd,
    this.onTapStop,
  });

  @override
  Widget build(BuildContext context) {
    // Colours
    final Color bg = isRecording
        ? const Color(0xFFFF3B30)
        : isVideoNoteMode
            ? const Color(0xFF0A84FF)
            : const Color(0xFF1F1F24);

    final Color fg = (isRecording || isVideoNoteMode)
        ? Colors.white
        : const Color(0xFFF5F5F5);

    final IconData icon = isRecording
        ? Icons.stop_rounded
        : isVideoNoteMode
            ? Icons.radio_button_checked
            : Icons.mic_rounded;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onTap: isRecording ? onTapStop : onTap,
          onLongPressStart: onHoldStart != null ? (_) => onHoldStart!() : null,
          onLongPressEnd: onHoldEnd != null ? (_) => onHoldEnd!() : null,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            width: isRecording ? 44 : 40,
            height: isRecording ? 44 : 40,
            decoration: BoxDecoration(
              color: bg,
              shape: BoxShape.circle,
              border: (!isRecording && !isVideoNoteMode)
                  ? Border.all(color: const Color(0xFF2C2C30))
                  : null,
              boxShadow: isRecording
                  ? [
                      BoxShadow(
                          color: const Color(0xFFFF3B30).withAlpha(80),
                          blurRadius: 12,
                          spreadRadius: 1)
                    ]
                  : null,
            ),
            child: Icon(icon, color: fg, size: 22),
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
