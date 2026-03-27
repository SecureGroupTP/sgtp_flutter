import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../blocs/chat/chat_bloc.dart';
import '../blocs/chat/chat_event.dart';
import '../blocs/chat/chat_state.dart';
import '../widgets/message_bubble.dart';

class ChatPage extends StatefulWidget {
  const ChatPage({super.key});

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final _messageCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  bool _infoShown = false;

  @override
  void dispose() {
    _messageCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
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
    final ext = name.split('.').last.toLowerCase();
    final mime = switch (ext) {
      'png' => 'image/png',
      'gif' => 'image/gif',
      'webp' => 'image/webp',
      _ => 'image/jpeg',
    };

    if (!context.mounted) return;
    context.read<ChatBloc>().add(
          ChatSendImage(bytes: file.bytes!, name: name, mime: mime),
        );
    _scrollToBottom();
  }

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<ChatBloc, ChatState>(
      listener: (context, state) {
        // Auto-scroll on new messages
        if (state.messages.isNotEmpty) _scrollToBottom();

        // Show room info once when ready
        if (state.status == ChatStatus.ready && !_infoShown) {
          _infoShown = true;
          _showRoomInfo(context, state);
        }

        // Navigate back on disconnect
        if (state.status == ChatStatus.disconnected) {
          Navigator.of(context).maybePop();
        }
      },
      builder: (context, state) {
        return PopScope(
          canPop: false,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) {
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
    final theme = Theme.of(context);
    return AppBar(
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('SGTP Chat'),
          if (state.roomUUID.isNotEmpty)
            Text(
              'Room: ${state.roomUUID.substring(0, 8)}…',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
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
        IconButton(
          icon: const Icon(Icons.logout),
          onPressed: () => context.read<ChatBloc>().add(const ChatDisconnect()),
          tooltip: 'Disconnect',
        ),
      ],
    );
  }

  Widget _buildStatusBanner(BuildContext context, ChatState state) {
    final theme = Theme.of(context);
    switch (state.status) {
      case ChatStatus.connecting:
        return _banner(context, Icons.wifi_find, 'Connecting to server…',
            theme.colorScheme.primaryContainer);
      case ChatStatus.handshaking:
        return _banner(context, Icons.handshake_outlined, 'Performing handshake…',
            theme.colorScheme.secondaryContainer);
      case ChatStatus.error:
        return _banner(
          context,
          Icons.error_outline,
          state.errorMessage ?? 'Error',
          theme.colorScheme.errorContainer,
        );
      case ChatStatus.ready:
      case ChatStatus.disconnected:
        return const SizedBox.shrink();
    }
  }

  Widget _banner(
    BuildContext context,
    IconData icon,
    String text,
    Color color,
  ) {
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
              strokeWidth: 2,
              color: theme.colorScheme.primary,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodySmall,
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
      itemBuilder: (context, index) {
        return MessageBubble(message: state.messages[index]);
      },
    );
  }

  Widget _buildInputBar(BuildContext context, ChatState state) {
    final canSend = state.status == ChatStatus.ready;
    return SafeArea(
      child: Container(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          boxShadow: [
            BoxShadow(
              color: Theme.of(context).colorScheme.shadow.withAlpha(30),
              blurRadius: 8,
              offset: const Offset(0, -2),
            ),
          ],
        ),
        child: Row(
          children: [
            IconButton(
              onPressed: canSend ? () => _pickAndSendImage(context) : null,
              icon: const Icon(Icons.image_outlined),
              tooltip: 'Send image',
            ),
            Expanded(
              child: TextField(
                controller: _messageCtrl,
                enabled: canSend,
                decoration: InputDecoration(
                  hintText: canSend ? 'Message…' : 'Waiting for chat key…',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                    borderSide: BorderSide.none,
                  ),
                  filled: true,
                  fillColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 10,
                  ),
                ),
                minLines: 1,
                maxLines: 5,
                textInputAction: TextInputAction.send,
                onSubmitted: canSend ? (_) => _sendMessage(context) : null,
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(
              onPressed: canSend ? () => _sendMessage(context) : null,
              icon: const Icon(Icons.send),
              tooltip: 'Send',
            ),
          ],
        ),
      ),
    );
  }

  void _showPeersSheet(BuildContext context, ChatState state) {
    showModalBottomSheet<void>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) {
        return Padding(
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
                ...state.peerUUIDs.map((uuid) => ListTile(
                      leading: const Icon(Icons.person_outline),
                      title: Text(uuid, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
                      trailing: IconButton(
                        icon: const Icon(Icons.copy, size: 18),
                        onPressed: () {
                          Clipboard.setData(ClipboardData(text: uuid));
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('UUID copied')),
                          );
                        },
                      ),
                    )),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
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
                Icon(Icons.star, size: 16, color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: 4),
                Text('You are the master',
                    style: TextStyle(color: Theme.of(context).colorScheme.primary)),
              ]),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Widget _infoRow(BuildContext context, String label, String value) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.primary,
        )),
        const SizedBox(height: 4),
        Row(
          children: [
            Expanded(
              child: SelectableText(
                value.isEmpty ? '—' : value,
                style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
              ),
            ),
            if (value.isNotEmpty)
              IconButton(
                icon: const Icon(Icons.copy, size: 16),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: value));
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('$label copied')),
                  );
                },
              ),
          ],
        ),
      ],
    );
  }
}
