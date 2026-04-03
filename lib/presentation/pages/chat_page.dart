import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:camera/camera.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:image/image.dart' as img;
import '../../core/app_logger.dart';
import '../../core/interaction_prefs.dart';
import '../../data/repositories/settings_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:image_picker/image_picker.dart';
import 'package:pasteboard/pasteboard.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../blocs/chat/chat_bloc.dart';
import '../blocs/chat/chat_event.dart';
import '../widgets/video_note_recorder.dart';
import '../blocs/chat/chat_state.dart';
import '../widgets/message_bubble.dart';
import '../../domain/entities/message.dart';
import '../../core/notification_service.dart';

class ChatPage extends StatefulWidget {
  final String accountId;
  const ChatPage({super.key, required this.accountId});

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> with WidgetsBindingObserver {
  static const int _maxUploadImageDimension = 2560;
  static const int _targetUploadImageBytes = 3 * 1024 * 1024;

  final _settingsRepo = SettingsRepository();
  final _messageCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  final _recorder = AudioRecorder();
  final _focusNode = FocusNode();
  bool _infoShown = false;
  bool _isRecording = false;
  String? _recordingPath;
  List<InputDevice> _microphones = const [];
  String? _selectedMicrophoneId;
  List<CameraDescription> _cameras = const [];
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

  static const _videoExtensions = {'mp4', 'mov', 'avi', 'webm', 'mkv', '3gp'};

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
    WidgetsBinding.instance.removeObserver(this);
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
        unawaited(_loadCaptureCapabilities());
        NotificationService.cancelAll();
        NotificationService.flushPendingMarkAsRead();

        final bloc = _chatBloc;
        if (bloc != null) {
          final bgDuration = _wentToBackground != null
              ? DateTime.now().difference(_wentToBackground!)
              : Duration.zero;
          _wentToBackground = null;

          final status = bloc.state.status;
          final isDown =
              status == ChatStatus.disconnected || status == ChatStatus.error;

          if (isDown) {
            AppLogger.w('[Chat] reconnecting after background '
                '(${bgDuration.inSeconds}s, status=$status)');
            bloc.add(const ChatReconnect());
          } else {
            AppLogger.i('[Chat] probing live connection after background '
                '(${bgDuration.inSeconds}s, status=$status)');
            bloc.add(const ChatProbeConnection());
          }
        }
        _flushPendingReadReceipts();
        break;

      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
        _wentToBackground ??= DateTime.now();
        setState(() => _isPageVisible = false);
        break;

      case AppLifecycleState.detached:
        // Do NOT disconnect here — see note in original code.
        break;
    }
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
    List<InputDevice> microphones = const [];
    List<CameraDescription> cameras = const [];
    try {
      microphones = await _recorder.listInputDevices();
    } catch (_) {}
    try {
      cameras = await availableCameras();
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
      if (cam.name == savedCameraName) {
        selectedCameraName = cam.name;
        break;
      }
    }
    selectedCameraName ??= cameras.isNotEmpty ? cameras.first.name : null;

    final hasMic = microphones.isNotEmpty;
    final hasCam = cameras.isNotEmpty;
    var videoMode = _isVideoNoteMode;
    if (!hasCam) videoMode = false;
    if (!hasMic && hasCam) videoMode = true;

    if (!mounted) return;
    setState(() {
      _microphones = microphones;
      _selectedMicrophoneId = selectedMicId;
      _cameras = cameras;
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
    SharedPreferences.getInstance().then((prefs) {
      prefs.setDouble('chat_scroll_$roomUUID', pos);
    }).catchError((_) {});
  }

  /// Restore the saved scroll position for [roomUUID], or jump to bottom if
  /// nothing was saved (first visit).
  Future<void> _tryRestoreScrollPosition(String roomUUID) async {
    if (roomUUID.isEmpty) {
      _scrollToBottom(jump: true);
      return;
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedPos = prefs.getDouble('chat_scroll_$roomUUID');
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
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: const Color(0xFF141417),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
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
            _SheetTile(
                icon: Icons.image_outlined,
                label: 'Photo / GIF',
                subtitle: 'Select one or more images',
                value: 'image',
                ctx: context),
            _SheetTile(
                icon: Icons.videocam_outlined,
                label: 'Video',
                subtitle: null,
                value: 'video',
                ctx: context),
            _SheetTile(
                icon: Icons.radio_button_checked_outlined,
                label: 'Video note',
                subtitle: 'Circular video message',
                value: 'videonote',
                ctx: context),
            _SheetTile(
                icon: Icons.content_paste_outlined,
                label: 'Paste from clipboard',
                subtitle: null,
                value: 'paste',
                ctx: context),
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
        context,
        imageCount: preparedFiles.length,
        initialCaption: existingText,
      );
      if (!context.mounted) return;
      if (captionResult == null) return; // user cancelled
      caption = captionResult;
    } else {
      caption = existingText;
    }

    final bloc = context.read<ChatBloc>();

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
    return showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF141417),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
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
  }

  Future<void> _pickAndSendVideoNote(BuildContext context) async {
    final result = await FilePicker.platform
        .pickFiles(type: FileType.video, withData: true);
    if (result == null || result.files.isEmpty) return;
    final file = result.files.first;
    if (file.bytes == null) return;
    if (!context.mounted) return;
    context
        .read<ChatBloc>()
        .add(ChatSendVideoNote(bytes: file.bytes!, mime: 'video/mp4'));
    _scrollToBottom();
  }

  Future<void> _pickAndSendVideo(BuildContext context) async {
    final mediaSettings = await _settingsRepo.loadMediaTransferSettings();
    final result = await FilePicker.platform
        .pickFiles(type: FileType.video, withData: true);
    if (result == null || result.files.isEmpty) return;
    final file = result.files.first;
    if (file.bytes == null) return;
    final ext = file.name.split('.').last.toLowerCase();
    if (!_videoExtensions.contains(ext)) {
      if (context.mounted) _showSnack(context, 'Unsupported format: .$ext');
      return;
    }
    final mime = switch (ext) {
      'mp4' => 'video/mp4',
      'mov' => 'video/quicktime',
      'webm' => 'video/webm',
      _ => 'video/mp4',
    };
    if (!context.mounted) return;
    if (mediaSettings.shouldCompressVideos) {
      _showSnack(
          context, 'Video compression is not available yet in this build');
    }
    context
        .read<ChatBloc>()
        .add(ChatSendVideo(bytes: file.bytes!, name: file.name, mime: mime));
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
      // Open full-screen camera recorder; get bytes back on close
      CameraDescription? preferred;
      for (final cam in _cameras) {
        if (cam.name == _selectedCameraName) {
          preferred = cam;
          break;
        }
      }
      final bytes = await Navigator.of(context).push<Uint8List?>(
        MaterialPageRoute(
          builder: (_) => VideoNoteRecorderPage(
            preferredCameraName: preferred?.name,
          ),
          fullscreenDialog: true,
        ),
      );
      if (bytes != null && context.mounted) {
        context
            .read<ChatBloc>()
            .add(ChatSendVideoNote(bytes: bytes, mime: 'video/mp4'));
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
      final tmpDir = await getTemporaryDirectory();
      _recordingPath =
          '${tmpDir.path}/voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
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
      final file = File(path);
      if (!file.existsSync() || file.lengthSync() == 0) return;
      final bytes = await file.readAsBytes();
      if (context.mounted) {
        if (_isVideoNoteMode) {
          // Video note (circle): audio-only fallback recorded as m4a,
          // sent as video_note type so the receiver renders it as a circle bubble.
          context
              .read<ChatBloc>()
              .add(ChatSendVideoNote(bytes: bytes, mime: 'audio/m4a'));
        } else {
          context
              .read<ChatBloc>()
              .add(ChatSendVoice(bytes: bytes, mime: 'audio/m4a'));
        }
        _scrollToBottom();
      }
      await file.delete().catchError((_) {});
    } catch (e) {
      setState(() {
        _isRecording = false;
        _isHoldRecording = false;
      });
      if (context.mounted) _showSnack(context, 'Error: $e');
    }
  }

  Future<void> _pasteImageFromClipboard(BuildContext context) async {
    try {
      final mediaSettings = await _settingsRepo.loadMediaTransferSettings();
      final imageBytes = await Pasteboard.image;
      if (imageBytes == null) {
        _showSnack(context, 'No image in clipboard');
        return;
      }
      if (!context.mounted) return;

      // Show preview dialog — let user confirm or cancel before sending.
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => _PastePreviewDialog(imageBytes: imageBytes),
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

      context.read<ChatBloc>().add(ChatSendImage(
            bytes: prepared.bytes,
            name: prepared.name,
            mime: prepared.mime,
          ));
      _scrollToBottom();
    } catch (e) {
      _showSnack(context, 'Failed to paste image: $e');
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

  /// Show dialog to edit chat name and avatar.
  void _showEditMetadataDialog(BuildContext context, ChatState state) {
    final nameCtrl = TextEditingController(text: state.chatName);
    Uint8List? newAvatar = state.chatAvatarBytes;

    showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: const Text('Edit Chat'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
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
                decoration: const InputDecoration(
                  labelText: 'Chat Name',
                  border: OutlineInputBorder(),
                ),
                maxLength: 100,
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel')),
            FilledButton(
              onPressed: () {
                final name = nameCtrl.text.trim();
                if (name.isEmpty) return;
                context.read<ChatBloc>().add(
                    ChatUpdateMetadata(name: name, avatarBytes: newAvatar));
                Navigator.pop(ctx);
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
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
          child: RawKeyboardListener(
            focusNode: FocusNode(),
            onKey: (event) {
              if (event.isKeyPressed(LogicalKeyboardKey.keyV) &&
                  (event.isControlPressed || event.isMetaPressed)) {
                // Check what's in the clipboard first.
                // If it's an image → show paste preview (regardless of focus).
                // If it's text → let the focused TextField handle it natively.
                Pasteboard.image.then((imageBytes) {
                  if (imageBytes != null && context.mounted) {
                    _pasteImageFromClipboard(context);
                  }
                  // If no image, do nothing — TextField already handled the
                  // text paste via its own keyboard shortcut processing.
                });
              }
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
                        child: Container(
                          width: 38,
                          height: 38,
                          decoration: BoxDecoration(
                            color: const Color(0xFF141417),
                            shape: BoxShape.circle,
                            border: Border.all(color: const Color(0xFF2C2C30)),
                          ),
                          child: ClipOval(
                            child: state.chatAvatarBytes != null
                                ? Image.memory(state.chatAvatarBytes!,
                                    fit: BoxFit.cover)
                                : const Center(
                                    child: Text('👽',
                                        style: TextStyle(fontSize: 18))),
                          ),
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
                      IconButton(
                        icon: const Icon(Icons.info_outline, size: 22),
                        color: const Color(0xFF8E8E93),
                        onPressed: () => _showRoomInfo(context, state),
                        padding: const EdgeInsets.all(4),
                        visualDensity: VisualDensity.compact,
                      ),
                      PopupMenuButton<_ChatMenuAction>(
                        icon: const Icon(Icons.more_vert,
                            size: 22, color: Color(0xFF8E8E93)),
                        padding: const EdgeInsets.all(4),
                        onSelected: (action) {
                          switch (action) {
                            case _ChatMenuAction.disconnect:
                              if (_isRecording) _recorder.stop();
                              context
                                  .read<ChatBloc>()
                                  .add(const ChatDisconnect());
                              if (context.mounted &&
                                  Navigator.of(context).canPop()) {
                                Navigator.of(context).pop();
                              }
                          }
                        },
                        itemBuilder: (_) => [
                          if (state.status == ChatStatus.ready)
                            const PopupMenuItem(
                              value: _ChatMenuAction.disconnect,
                              child: ListTile(
                                leading: Icon(Icons.logout),
                                title: Text('Disconnect'),
                                contentPadding: EdgeInsets.zero,
                              ),
                            ),
                          PopupMenuItem(
                            onTap: () =>
                                _showEditMetadataDialog(context, state),
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
        return _disconnectedBanner(context);
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
          Text(
            text,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  Widget _disconnectedBanner(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Color(0x26636366),
        border: Border(bottom: BorderSide(color: Color(0x33636366))),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.wifi_off_rounded,
              size: 14, color: Color(0xFF8E8E93)),
          const SizedBox(width: 8),
          const Expanded(
            child: Text(
              'Disconnected',
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: Color(0xFF8E8E93)),
            ),
          ),
          GestureDetector(
            onTap: () => context.read<ChatBloc>().add(const ChatReconnect()),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: const Color(0x1AFFFFFF),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.wifi_rounded, size: 14, color: Color(0xFFF5F5F5)),
                  SizedBox(width: 4),
                  Text('Reconnect',
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: Color(0xFFF5F5F5))),
                ],
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
                  : 'Waiting for connection…',
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
          peerCount: state.peerUUIDs.length,
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
                        onSubmitted:
                            canSend ? (_) => _sendMessage(context) : null,
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
                        onHoldEnd: canSend && _isRecording
                            ? () => _stopHoldRecording(context)
                            : null,
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

  void _showRoomInfo(BuildContext context, ChatState state) {
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Room info'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _infoRow(context, 'Room UUID', state.roomUUID),
            const SizedBox(height: 12),
            _infoRow(context, 'My UUID', state.myUUID),
            const SizedBox(height: 12),
            _infoRow(context, 'My public key', state.myPublicKeyHex),
            if (state.isMaster) ...[
              const SizedBox(height: 12),
              Row(children: [
                Icon(Icons.star,
                    size: 16, color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: 4),
                Text('You are the master',
                    style: TextStyle(
                        color: Theme.of(context).colorScheme.primary)),
              ]),
            ],
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close')),
        ],
      ),
    );
  }

  Widget _infoRow(BuildContext context, String label, String value) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: theme.textTheme.labelSmall
                ?.copyWith(color: theme.colorScheme.primary)),
        const SizedBox(height: 4),
        Row(children: [
          Expanded(
            child: SelectableText(value.isEmpty ? '—' : value,
                style: theme.textTheme.bodySmall
                    ?.copyWith(fontFamily: 'monospace')),
          ),
          if (value.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.copy, size: 16),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: value));
                Navigator.pop(context);
                _showSnack(context, '$label copied');
              },
            ),
        ]),
      ],
    );
  }
}

enum _ChatMenuAction { disconnect }

// ─────────────────────────────────────────────────────────────────────────────
// Media picker sheet tile
// ─────────────────────────────────────────────────────────────────────────────

class _SheetTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String? subtitle;
  final String value;
  final BuildContext ctx;

  const _SheetTile({
    required this.icon,
    required this.label,
    this.subtitle,
    required this.value,
    required this.ctx,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => Navigator.pop(ctx, value),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        child: Row(children: [
          Icon(icon, color: const Color(0xFF8E8E93), size: 22),
          const SizedBox(width: 16),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(label,
                  style: const TextStyle(
                      color: Color(0xFFF5F5F5),
                      fontSize: 16,
                      fontWeight: FontWeight.w400)),
              if (subtitle != null)
                Text(subtitle!,
                    style: const TextStyle(
                        color: Color(0xFF8E8E93), fontSize: 12)),
            ],
          ),
        ]),
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
// Paste preview dialog (Fix 4)
// ─────────────────────────────────────────────────────────────────────────────

class _PastePreviewDialog extends StatelessWidget {
  final Uint8List imageBytes;
  const _PastePreviewDialog({required this.imageBytes});

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF1F1F24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Send image?',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: Color(0xFFF5F5F5),
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 280),
                child: Image.memory(
                  imageBytes,
                  fit: BoxFit.contain,
                ),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(context, false),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFF8E8E93),
                      side: const BorderSide(color: Color(0xFF2C2C30)),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                    ),
                    child: const Text('Cancel'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    onPressed: () => Navigator.pop(context, true),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF0A84FF),
                      foregroundColor: Colors.white,
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                    ),
                    child: const Text('Send'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
