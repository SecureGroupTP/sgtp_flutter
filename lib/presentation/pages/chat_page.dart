import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../blocs/chat/chat_bloc.dart';
import '../blocs/chat/chat_event.dart';
import '../blocs/chat/chat_state.dart';
import '../widgets/message_bubble.dart';

class ChatPage extends StatefulWidget {
  const ChatPage({super.key});

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> with WidgetsBindingObserver {
  final _messageCtrl  = TextEditingController();
  final _scrollCtrl   = ScrollController();
  final _recorder     = AudioRecorder();
  bool _infoShown     = false;
  bool _isRecording   = false;
  String? _recordingPath;
  List<InputDevice> _inputDevices = [];
  InputDevice? _selectedDevice;

  // Keep a local reference for the lifecycle observer
  ChatBloc? _chatBloc;

  // Allowed video extensions — guards against PDF/doc being sent as video
  static const _videoExtensions = {'mp4', 'mov', 'avi', 'webm', 'mkv', '3gp'};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadInputDevices();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _messageCtrl.dispose();
    _scrollCtrl.dispose();
    _recorder.dispose();
    super.dispose();
  }

  /// Graceful shutdown when OS is about to kill the app.
  @override
  void didChangeAppLifecycleState(AppLifecycleState appState) {
    if (appState == AppLifecycleState.detached) {
      _chatBloc?.add(const ChatDisconnect());
    }
  }

  Future<void> _loadInputDevices() async {
    try {
      final devices = await _recorder.listInputDevices();
      if (mounted) {
        setState(() => _inputDevices = devices);
      }
    } catch (_) {}
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(
          _scrollCtrl.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _sendMessage(BuildContext context) {
    final text = _messageCtrl.text.trim();
    if (text.isEmpty) return;
    context.read<ChatBloc>().add(ChatSendMessage(text));
    _messageCtrl.clear();
    _scrollToBottom();
  }

  Future<void> _pickAndSendImage(BuildContext context) async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;
    final file = result.files.first;
    if (file.bytes == null) return;

    final name = file.name;
    final ext  = name.split('.').last.toLowerCase();
    final mime = switch (ext) {
      'png'  => 'image/png',
      'gif'  => 'image/gif',
      'webp' => 'image/webp',
      _      => 'image/jpeg',
    };

    if (!context.mounted) return;
    context.read<ChatBloc>().add(
          ChatSendImage(bytes: file.bytes!, name: name, mime: mime),
        );
    _scrollToBottom();
  }

  Future<void> _pickAndSendVideo(BuildContext context) async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.video,
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;
    final file = result.files.first;
    if (file.bytes == null) return;

    final name = file.name;
    final ext  = name.split('.').last.toLowerCase();

    // Guard: reject non-video files (e.g. PDF that slipped through on Android)
    if (!_videoExtensions.contains(ext)) {
      if (context.mounted) {
        _showFloatingSnackbar(context, 'Unsupported format: .$ext (expected video)');
      }
      return;
    }

    final mime = switch (ext) {
      'mp4'  => 'video/mp4',
      'mov'  => 'video/quicktime',
      'avi'  => 'video/x-msvideo',
      'webm' => 'video/webm',
      'mkv'  => 'video/x-matroska',
      _      => 'video/mp4',
    };

    if (!context.mounted) return;
    context.read<ChatBloc>().add(
          ChatSendVideo(bytes: file.bytes!, name: name, mime: mime),
        );
    _scrollToBottom();
  }

  Future<void> _toggleRecording(BuildContext context) async {
    if (_isRecording) {
      await _stopAndSend(context);
    } else {
      await _startRecording(context);
    }
  }

  Future<void> _startRecording(BuildContext context) async {
    final hasPermission = await _recorder.hasPermission();
    if (!hasPermission) {
      if (context.mounted) _showFloatingSnackbar(context, 'No microphone permission');
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
          device: _selectedDevice,
        ),
        path: _recordingPath!,
      );

      setState(() => _isRecording = true);
    } catch (e) {
      if (context.mounted) _showFloatingSnackbar(context, 'Record error: $e');
    }
  }

  Future<void> _stopAndSend(BuildContext context) async {
    try {
      final path = await _recorder.stop();
      setState(() => _isRecording = false);

      if (path == null) return;
      final file = File(path);
      if (!file.existsSync() || file.lengthSync() == 0) return;

      final bytes = await file.readAsBytes();
      if (context.mounted) {
        context.read<ChatBloc>().add(ChatSendVoice(bytes: bytes, mime: 'audio/m4a'));
        _scrollToBottom();
      }

      await file.delete().catchError((_) {});
      _recordingPath = null;
    } catch (e) {
      setState(() => _isRecording = false);
      if (context.mounted) _showFloatingSnackbar(context, 'Error: $e');
    }
  }

  void _showFloatingSnackbar(BuildContext context, String text) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(text),
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 80),
      ),
    );
  }

  void _showMicPicker(BuildContext context) async {
    await _loadInputDevices();
    if (!context.mounted) return;
    if (_inputDevices.isEmpty) {
      _showFloatingSnackbar(context, 'No microphones found');
      return;
    }

    showModalBottomSheet<void>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) {
        return StatefulBuilder(
          builder: (ctx, setSheetState) => Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Select microphone',
                    style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                ..._inputDevices.map((device) => RadioListTile<InputDevice>(
                      title: Text(device.label),
                      value: device,
                      groupValue: _selectedDevice,
                      onChanged: (d) {
                        setSheetState(() => _selectedDevice = d);
                        setState(() => _selectedDevice = d);
                        Navigator.pop(ctx);
                      },
                    )),
                const SizedBox(height: 8),
              ],
            ),
          ),
        );
      },
    );
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<ChatBloc, ChatState>(
      listener: (context, state) {
        // Capture the bloc reference for lifecycle observer
        _chatBloc ??= context.read<ChatBloc>();

        if (state.messages.isNotEmpty) _scrollToBottom();

        if (state.status == ChatStatus.ready && !_infoShown) {
          _infoShown = true;
          _showRoomInfo(context, state);
        }

        // Use pop() not maybePop() — maybePop() respects PopScope.canPop:false
        // and won't pop, causing the page to get stuck after disconnect.
        if (state.status == ChatStatus.disconnected) {
          if (Navigator.of(context).canPop()) {
            Navigator.of(context).pop();
          }
        }
      },
      builder: (context, state) {
        return PopScope(
          canPop: false,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) {
              if (_isRecording) _recorder.stop();
              context.read<ChatBloc>().add(const ChatDisconnect());
            }
          },
          child: Scaffold(
            appBar: _buildAppBar(context, state),
            body: Column(
              children: [
                _buildStatusBanner(context, state),
                Expanded(child: _buildMessageList(state)),
                _buildInputBar(context, state),
              ],
            ),
          ),
        );
      },
    );
  }

  PreferredSizeWidget _buildAppBar(BuildContext context, ChatState state) {
    final theme       = Theme.of(context);
    final roomDisplay = state.roomUUID.isNotEmpty ? state.roomUUID : '…';

    return AppBar(
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('SGTP Chat'),
          if (state.roomUUID.isNotEmpty)
            GestureDetector(
              onTap: () {
                Clipboard.setData(ClipboardData(text: state.roomUUID));
                _showFloatingSnackbar(context, 'Room UUID copied');
              },
              child: Text(
                roomDisplay,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontFamily: 'monospace',
                ),
              ),
            ),
        ],
      ),
      actions: [
        if (state.status == ChatStatus.ready)
          IconButton(
            icon: Badge(
              label: Text('${state.peerUUIDs.length}'),
              isLabelVisible: state.peerUUIDs.isNotEmpty,
              child: const Icon(Icons.people_outline),
            ),
            onPressed: () => _showPeersSheet(context, state),
            tooltip: 'Peers',
          ),
        IconButton(
          icon: const Icon(Icons.info_outline),
          onPressed: () => _showRoomInfo(context, state),
          tooltip: 'Room info',
        ),
        // ── Chat menu ─────────────────────────────────────────────────────
        PopupMenuButton<_ChatMenuAction>(
          icon: const Icon(Icons.more_vert),
          onSelected: (action) {
            switch (action) {
              case _ChatMenuAction.newChat:
                // Disconnect → listener pops back → SetupPage pre-filled → new connect
                if (_isRecording) _recorder.stop();
                context.read<ChatBloc>().add(const ChatDisconnect());
              case _ChatMenuAction.disconnect:
                if (_isRecording) _recorder.stop();
                context.read<ChatBloc>().add(const ChatDisconnect());
            }
          },
          itemBuilder: (_) => const [
            PopupMenuItem(
              value: _ChatMenuAction.newChat,
              child: ListTile(
                leading: Icon(Icons.add_circle_outline),
                title: Text('New chat'),
                subtitle: Text('Return to setup & start fresh'),
                contentPadding: EdgeInsets.zero,
              ),
            ),
            PopupMenuDivider(),
            PopupMenuItem(
              value: _ChatMenuAction.disconnect,
              child: ListTile(
                leading: Icon(Icons.logout),
                title: Text('Disconnect'),
                contentPadding: EdgeInsets.zero,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildStatusBanner(BuildContext context, ChatState state) {
    final theme = Theme.of(context);
    switch (state.status) {
      case ChatStatus.connecting:
        return _banner(context, 'Connecting to server…',
            theme.colorScheme.primaryContainer);
      case ChatStatus.handshaking:
        return _banner(context, 'Performing handshake…',
            theme.colorScheme.secondaryContainer);
      case ChatStatus.error:
        return _banner(context, state.errorMessage ?? 'Error',
            theme.colorScheme.errorContainer);
      case ChatStatus.ready:
      case ChatStatus.disconnected:
        return const SizedBox.shrink();
    }
  }

  Widget _banner(BuildContext context, String text, Color color) {
    final theme = Theme.of(context);
    return Container(
      color: color,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
                strokeWidth: 2, color: theme.colorScheme.primary),
          ),
          const SizedBox(width: 12),
          Expanded(child: Text(text, style: theme.textTheme.bodySmall)),
        ],
      ),
    );
  }

  Widget _buildMessageList(ChatState state) {
    if (state.messages.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.chat_bubble_outline,
                  size: 64,
                  color: Theme.of(context).colorScheme.outlineVariant),
              const SizedBox(height: 16),
              Text(
                state.status == ChatStatus.ready
                    ? 'No messages yet. Say hello!'
                    : 'Waiting for connection…',
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
            ],
          ),
        ),
      );
    }

    return ListView.builder(
      controller: _scrollCtrl,
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: state.messages.length,
      itemBuilder: (context, index) => MessageBubble(
        message: state.messages[index],
        peerNicknames: state.peerNicknames,
      ),
    );
  }

  Widget _buildInputBar(BuildContext context, ChatState state) {
    final canSend = state.status == ChatStatus.ready;
    final theme   = Theme.of(context);

    return SafeArea(
      child: Container(
        padding: const EdgeInsets.fromLTRB(4, 6, 8, 6),
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          boxShadow: [
            BoxShadow(
              color: theme.colorScheme.shadow.withAlpha(30),
              blurRadius: 8,
              offset: const Offset(0, -2),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_isRecording)
              Container(
                margin: const EdgeInsets.only(bottom: 6),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: theme.colorScheme.errorContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.fiber_manual_record,
                        size: 12, color: theme.colorScheme.error),
                    const SizedBox(width: 6),
                    Text(
                      'Recording… tap again to send',
                      style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onErrorContainer),
                    ),
                  ],
                ),
              ),
            Row(
              children: [
                IconButton(
                  onPressed: canSend ? () => _pickAndSendImage(context) : null,
                  icon: const Icon(Icons.image_outlined),
                  tooltip: 'Send photo / GIF',
                ),
                IconButton(
                  onPressed: canSend ? () => _pickAndSendVideo(context) : null,
                  icon: const Icon(Icons.videocam_outlined),
                  tooltip: 'Send video',
                ),
                GestureDetector(
                  onLongPress: canSend ? () => _showMicPicker(context) : null,
                  child: IconButton(
                    onPressed: canSend ? () => _toggleRecording(context) : null,
                    icon: Icon(
                      _isRecording ? Icons.stop_circle : Icons.mic_outlined,
                      color: _isRecording ? theme.colorScheme.error : null,
                    ),
                    tooltip: _isRecording
                        ? 'Stop & send'
                        : 'Record (long-press to pick mic)',
                  ),
                ),
                Expanded(
                  child: TextField(
                    controller: _messageCtrl,
                    enabled: canSend && !_isRecording,
                    decoration: InputDecoration(
                      hintText: _isRecording
                          ? 'Recording…'
                          : canSend
                              ? 'Message…'
                              : 'Waiting for chat key…',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                        borderSide: BorderSide.none,
                      ),
                      filled: true,
                      fillColor: theme.colorScheme.surfaceContainerHighest,
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 10),
                    ),
                    minLines: 1,
                    maxLines: 5,
                    textInputAction: TextInputAction.send,
                    onSubmitted: canSend ? (_) => _sendMessage(context) : null,
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  onPressed: canSend && !_isRecording
                      ? () => _sendMessage(context)
                      : null,
                  icon: const Icon(Icons.send),
                  tooltip: 'Send',
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ── Sheets / dialogs ──────────────────────────────────────────────────────

  void _showPeersSheet(BuildContext context, ChatState state) {
    showModalBottomSheet<void>(
      context: context,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Connected peers',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            if (state.peerUUIDs.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: Center(child: Text('No peers connected')),
              )
            else
              ...state.peerUUIDs.map((uuid) {
                final nick = state.peerNicknames[uuid];
                return ListTile(
                  leading: const Icon(Icons.person_outline),
                  title: Text(
                    nick != null
                        ? '$nick  ·  ${uuid.substring(0, 8)}…'
                        : uuid,
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                  ),
                  trailing: IconButton(
                    icon: const Icon(Icons.copy, size: 18),
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: uuid));
                      Navigator.pop(context);
                      _showFloatingSnackbar(context, 'UUID copied');
                    },
                  ),
                );
              }),
            const SizedBox(height: 8),
          ],
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
        Row(
          children: [
            Expanded(
              child: SelectableText(
                value.isEmpty ? '—' : value,
                style: theme.textTheme.bodySmall
                    ?.copyWith(fontFamily: 'monospace'),
              ),
            ),
            if (value.isNotEmpty)
              IconButton(
                icon: const Icon(Icons.copy, size: 16),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: value));
                  Navigator.pop(context);
                  _showFloatingSnackbar(context, '$label copied');
                },
              ),
          ],
        ),
      ],
    );
  }
}

// ── Menu action enum ──────────────────────────────────────────────────────────

enum _ChatMenuAction { newChat, disconnect }
