import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/qr_data.dart';
import '../../data/repositories/settings_repository.dart';
import '../blocs/chat/chat_bloc.dart';
import '../blocs/chat/chat_event.dart';
import '../blocs/chat/chat_state.dart';
import '../blocs/rooms/rooms_bloc.dart';
import '../blocs/rooms/rooms_event.dart';
import '../blocs/rooms/rooms_state.dart';
import '../widgets/qr_share_dialog.dart';
import '../widgets/qr_scanner_dialog.dart';
import 'chat_page.dart';

bool get _isDesktop =>
    !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);

class RoomsPage extends StatefulWidget {
  const RoomsPage({super.key});

  @override
  State<RoomsPage> createState() => _RoomsPageState();
}

class _RoomsPageState extends State<RoomsPage> {
  final _settingsRepo = SettingsRepository();
  List<String> _savedUUIDs = [];

  @override
  void initState() {
    super.initState();
    _loadSavedChats();
  }

  Future<void> _loadSavedChats() async {
    final uuids = await _settingsRepo.loadSavedChatUUIDs();
    if (mounted) setState(() => _savedUUIDs = uuids);
  }

  Future<void> _saveChat(String uuid) async {
    await _settingsRepo.addSavedChat(uuid);
    await _loadSavedChats();
  }

  Future<void> _unsaveChat(String uuid) async {
    await _settingsRepo.removeSavedChat(uuid);
    await _loadSavedChats();
  }

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<RoomsBloc, RoomsState>(
      listener: (context, state) {
        if (state.error != null) {
          ScaffoldMessenger.of(context)
            ..hideCurrentSnackBar()
            ..showSnackBar(SnackBar(
              content: Text(state.error!),
              backgroundColor: Theme.of(context).colorScheme.error,
            ));
        }
      },
      builder: (context, state) {
        return Scaffold(
          appBar: _buildAppBar(context, state),
          body: state.rooms.isEmpty
              ? _buildEmpty(context)
              : _buildRoomList(context, state),
          floatingActionButton: FloatingActionButton(
            onPressed: () => _showAddSheet(context),
            tooltip: 'Add room',
            child: const Icon(Icons.add),
          ),
        );
      },
    );
  }

  PreferredSizeWidget _buildAppBar(BuildContext context, RoomsState state) {
    final theme = Theme.of(context);
    final statuses = state.rooms.map((r) => r.chatBloc.state.status).toList();
    final Color dotColor;
    if (statuses.any((s) => s == ChatStatus.ready)) {
      dotColor = Colors.green;
    } else if (statuses.any(
        (s) => s == ChatStatus.connecting || s == ChatStatus.handshaking)) {
      dotColor = Colors.orange;
    } else if (statuses.isNotEmpty) {
      dotColor = Colors.red;
    } else {
      dotColor = theme.colorScheme.outlineVariant;
    }

    return AppBar(
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('SGTP Chat'),
          Text(
            state.serverAddress,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontFamily: 'monospace',
            ),
          ),
        ],
      ),
      actions: [
        Padding(
          padding: const EdgeInsets.only(right: 16),
          child: Tooltip(
            message: _statusTooltip(statuses),
            child: Container(
              width: 12, height: 12,
              decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
            ),
          ),
        ),
      ],
    );
  }

  String _statusTooltip(List<ChatStatus> statuses) {
    if (statuses.isEmpty) return 'No active rooms';
    if (statuses.any((s) => s == ChatStatus.ready)) return 'Connected';
    if (statuses.any((s) => s == ChatStatus.connecting || s == ChatStatus.handshaking)) {
      return 'Connecting…';
    }
    return 'Disconnected';
  }

  Widget _buildEmpty(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.meeting_room_outlined,
                size: 72, color: theme.colorScheme.outlineVariant),
            const SizedBox(height: 16),
            Text('No rooms yet',
                style: theme.textTheme.titleMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant)),
            const SizedBox(height: 8),
            Text(
              'Tap + to create a new room or join an existing one by UUID.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRoomList(BuildContext context, RoomsState state) {
    final theme = Theme.of(context);
    // Determine which saved UUIDs are not currently active
    final activeUUIDs = state.rooms.map((r) => r.roomUUID).toSet();
    final savedNotActive = _savedUUIDs.where((u) => !activeUUIDs.contains(u)).toList();

    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        // ── Active rooms ─────────────────────────────────────────────────
        if (state.rooms.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text('Active', style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant)),
          ),
          ...state.rooms.map((entry) => _RoomTile(
            entry: entry,
            serverAddress: state.serverAddress,
            isSaved: _savedUUIDs.contains(entry.roomUUID),
            onTap: () => _openRoom(context, entry),
            onRemove: () =>
                context.read<RoomsBloc>().add(RoomsRemoveRoom(entry.roomUUID)),
            onToggleSave: () async {
              if (_savedUUIDs.contains(entry.roomUUID)) {
                await _unsaveChat(entry.roomUUID);
              } else {
                await _saveChat(entry.roomUUID);
              }
            },
          )),
        ],

        // ── Saved chats (not currently joined) ───────────────────────────
        if (savedNotActive.isNotEmpty) ...[
          const Divider(height: 24, indent: 16, endIndent: 16),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Text('Saved Chats', style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant)),
          ),
          ...savedNotActive.map((uuid) => _SavedChatTile(
            uuid: uuid,
            onConnect: () {
              context.read<RoomsBloc>().add(RoomsJoinRoom(uuid));
            },
            onRemove: () => _unsaveChat(uuid),
          )),
        ],
      ],
    );
  }

  void _openRoom(BuildContext context, RoomEntry entry) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => BlocProvider.value(
          value: entry.chatBloc,
          child: const ChatPage(),
        ),
      ),
    );
  }

  void _showAddSheet(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (sheetCtx) => _AddRoomSheet(
        roomsBloc: context.read<RoomsBloc>(),
        onSaveChat: _saveChat,
      ),
    );
  }
}

// ── Room tile ──────────────────────────────────────────────────────────────

class _RoomTile extends StatelessWidget {
  final RoomEntry entry;
  final String serverAddress;
  final bool isSaved;
  final VoidCallback onTap;
  final VoidCallback onRemove;
  final VoidCallback onToggleSave;

  const _RoomTile({
    required this.entry,
    required this.serverAddress,
    required this.isSaved,
    required this.onTap,
    required this.onRemove,
    required this.onToggleSave,
  });

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<ChatBloc, ChatState>(
      bloc: entry.chatBloc,
      builder: (context, chatState) {
        final statusColor = _statusColor(context, chatState.status);
        final statusText  = _statusText(chatState.status);
        final isDisconnected = chatState.status == ChatStatus.disconnected
            || chatState.status == ChatStatus.error;

        return ListTile(
          leading: CircleAvatar(
            backgroundImage: chatState.chatAvatarBytes != null
                ? MemoryImage(chatState.chatAvatarBytes!) : null,
            backgroundColor: chatState.chatAvatarBytes == null
                ? Theme.of(context).colorScheme.secondaryContainer : null,
            child: chatState.chatAvatarBytes == null
                ? Icon(Icons.meeting_room_outlined,
                    color: Theme.of(context).colorScheme.onSecondaryContainer)
                : null,
          ),
          title: Text(
            chatState.chatName != 'Chat'
                ? chatState.chatName
                : entry.label,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Row(
            children: [
              Container(
                width: 8, height: 8,
                margin: const EdgeInsets.only(right: 6, top: 1),
                decoration: BoxDecoration(color: statusColor, shape: BoxShape.circle),
              ),
              Text(statusText),
              if (chatState.peerUUIDs.isNotEmpty) ...[
                const SizedBox(width: 8),
                Text(
                  '· ${chatState.peerUUIDs.length} peer${chatState.peerUUIDs.length == 1 ? '' : 's'}',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant),
                ),
              ],
            ],
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Reconnect button when disconnected/error
              if (isDisconnected)
                IconButton(
                  icon: const Icon(Icons.wifi_rounded),
                  tooltip: 'Reconnect',
                  color: Theme.of(context).colorScheme.primary,
                  onPressed: () => entry.chatBloc.add(const ChatReconnect()),
                ),
              PopupMenuButton<_RoomAction>(
                icon: const Icon(Icons.more_vert),
                onSelected: (action) {
                  switch (action) {
                    case _RoomAction.open:
                      onTap();
                    case _RoomAction.copyUUID:
                      Clipboard.setData(ClipboardData(text: entry.roomUUID));
                      ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Room UUID copied')));
                    case _RoomAction.shareQR:
                      final qrData = QrShareData(
                        type: 'room',
                        roomUUID: entry.roomUUID,
                        serverAddress: serverAddress,
                        timestamp: DateTime.now().millisecondsSinceEpoch,
                      );
                      showDialog<void>(
                        context: context,
                        builder: (_) => QrShareDialog(
                          data: qrData,
                          title: 'Share Room',
                          description: chatState.chatName != 'Chat'
                              ? chatState.chatName
                              : entry.label,
                        ),
                      );
                    case _RoomAction.save:
                      onToggleSave();
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                        content: Text(isSaved ? 'Removed from saved' : 'Chat saved'),
                      ));
                    case _RoomAction.remove:
                      onRemove();
                  }
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(
                    value: _RoomAction.open,
                    child: ListTile(
                      leading: Icon(Icons.open_in_new),
                      title: Text('Open'),
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                  const PopupMenuItem(
                    value: _RoomAction.copyUUID,
                    child: ListTile(
                      leading: Icon(Icons.copy),
                      title: Text('Copy UUID'),
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                  const PopupMenuItem(
                    value: _RoomAction.shareQR,
                    child: ListTile(
                      leading: Icon(Icons.qr_code_2),
                      title: Text('Share QR code'),
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                  PopupMenuItem(
                    value: _RoomAction.save,
                    child: ListTile(
                      leading: Icon(isSaved ? Icons.bookmark_remove_outlined : Icons.bookmark_add_outlined),
                      title: Text(isSaved ? 'Remove from saved' : 'Save chat'),
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                  const PopupMenuDivider(),
                  const PopupMenuItem(
                    value: _RoomAction.remove,
                    child: ListTile(
                      leading: Icon(Icons.delete_outline),
                      title: Text('Remove'),
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                ],
              ),
            ],
          ),
          onTap: onTap,
        );
      },
    );
  }

  Color _statusColor(BuildContext context, ChatStatus status) {
    return switch (status) {
      ChatStatus.ready       => Colors.green,
      ChatStatus.connecting  => Colors.orange,
      ChatStatus.handshaking => Colors.orange,
      ChatStatus.error       => Colors.red,
      ChatStatus.disconnected => Theme.of(context).colorScheme.outlineVariant,
    };
  }

  String _statusText(ChatStatus status) {
    return switch (status) {
      ChatStatus.ready        => 'Ready',
      ChatStatus.connecting   => 'Connecting…',
      ChatStatus.handshaking  => 'Handshaking…',
      ChatStatus.error        => 'Error',
      ChatStatus.disconnected => 'Disconnected',
    };
  }
}

enum _RoomAction { open, copyUUID, shareQR, save, remove }

// ── Add room bottom sheet ─────────────────────────────────────────────────

// ── Saved chat tile (for chats saved but not currently joined) ──────────────

class _SavedChatTile extends StatelessWidget {
  final String uuid;
  final VoidCallback onConnect;
  final VoidCallback onRemove;

  const _SavedChatTile({
    required this.uuid,
    required this.onConnect,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: theme.colorScheme.secondaryContainer,
        child: Icon(Icons.bookmark_outlined,
            color: theme.colorScheme.onSecondaryContainer),
      ),
      title: Text(
        uuid.substring(0, 16) + '…',
        style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
      ),
      subtitle: Text('Saved · tap to connect',
          style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: Icon(Icons.copy, size: 18, color: theme.colorScheme.onSurfaceVariant),
            tooltip: 'Copy UUID',
            onPressed: () {
              Clipboard.setData(ClipboardData(text: uuid));
              ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('UUID copied')));
            },
          ),
          IconButton(
            icon: const Icon(Icons.bookmark_remove_outlined, size: 18, color: Colors.red),
            tooltip: 'Remove from saved',
            onPressed: onRemove,
          ),
        ],
      ),
      onTap: onConnect,
    );
  }
}

// ── Add room bottom sheet ─────────────────────────────────────────────────

class _AddRoomSheet extends StatefulWidget {
  final RoomsBloc roomsBloc;
  final Future<void> Function(String uuid)? onSaveChat;
  const _AddRoomSheet({required this.roomsBloc, this.onSaveChat});

  @override
  State<_AddRoomSheet> createState() => _AddRoomSheetState();
}

class _AddRoomSheetState extends State<_AddRoomSheet> {
  final _uuidCtrl   = TextEditingController();
  final _base64Ctrl = TextEditingController();
  bool _joining          = false;
  bool _showBase64Input  = false;
  bool _saveAfterJoin    = false;
  String? _decodeError;

  @override
  void dispose() {
    _uuidCtrl.dispose();
    _base64Ctrl.dispose();
    super.dispose();
  }

  void _handleQrScanned(QrShareData data) {
    // QrScannerDialog already popped itself — just join and close the sheet.
    if (data.type == 'room' && data.roomUUID != null) {
      widget.roomsBloc.add(RoomsJoinRoom(data.roomUUID!));
      Navigator.of(context).pop(); // close the add-room bottom sheet
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Invalid room QR code')),
      );
    }
  }

  /// Decode base64, validate, and immediately join if valid.
  void _joinFromBase64() {
    final raw = _base64Ctrl.text.trim();
    if (raw.isEmpty) return;

    final data = QrShareData.fromBase64(raw);
    if (data != null && data.type == 'room' && data.roomUUID != null) {
      widget.roomsBloc.add(RoomsJoinRoom(data.roomUUID!));
      Navigator.of(context).pop();
    } else {
      // Maybe the user pasted a raw UUID hex directly in the base64 field
      final hex = raw.replaceAll('-', '');
      if (hex.length == 32 && RegExp(r'^[0-9a-fA-F]+$').hasMatch(hex)) {
        widget.roomsBloc.add(RoomsJoinRoom(hex));
        Navigator.of(context).pop();
      } else {
        setState(() => _decodeError = 'Could not parse — paste valid base64 or 32-char hex UUID');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(
          24, 24, 24, MediaQuery.of(context).viewInsets.bottom + 24),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Add room', style: theme.textTheme.titleLarge),
            const SizedBox(height: 24),

            // Create new
            FilledButton.icon(
              onPressed: () {
                widget.roomsBloc.add(const RoomsCreateRoom());
                Navigator.of(context).pop();
              },
              icon: const Icon(Icons.add_circle_outline),
              label: const Text('Create new room'),
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            ),
            const SizedBox(height: 16),
            const _Divider(),
            const SizedBox(height: 16),

            // Scan QR — mobile only
            if (!_isDesktop) ...[
              FilledButton.tonalIcon(
                onPressed: () {
                  Navigator.push<void>(
                    context,
                    MaterialPageRoute(
                      fullscreenDialog: true,
                      builder: (_) => QrScannerDialog(onQrScanned: _handleQrScanned),
                    ),
                  );
                },
                icon: const Icon(Icons.qr_code_scanner),
                label: const Text('Scan QR code'),
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
              ),
              const SizedBox(height: 12),
              const _Divider(),
              const SizedBox(height: 12),
            ],

            // Join by UUID
            if (!_showBase64Input) ...[
              TextField(
                controller: _uuidCtrl,
                decoration: const InputDecoration(
                  labelText: 'Room UUID',
                  hintText: '32 hex chars (without dashes)',
                  prefixIcon: Icon(Icons.vpn_key_outlined),
                  border: OutlineInputBorder(),
                ),
                onChanged: (v) => setState(() {
                  _joining = v.trim().isNotEmpty;
                  _decodeError = null;
                }),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: () => setState(() {
                  _showBase64Input = true;
                  _decodeError = null;
                }),
                child: const Text('Or paste base64 / QR data'),
              ),
            ] else ...[
              // Join by base64
              TextField(
                controller: _base64Ctrl,
                maxLines: 3,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: 'Base64 QR data or UUID',
                  hintText: 'Paste base64 string or 32-char hex here',
                  prefixIcon: const Icon(Icons.vpn_key_outlined),
                  border: const OutlineInputBorder(),
                  errorText: _decodeError,
                ),
                onChanged: (v) => setState(() {
                  _joining = v.trim().isNotEmpty;
                  _decodeError = null;
                }),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: () => setState(() {
                  _showBase64Input = false;
                  _base64Ctrl.clear();
                  _decodeError = null;
                }),
                child: const Text('Back to UUID input'),
              ),
            ],

            const SizedBox(height: 12),
            CheckboxListTile(
              value: _saveAfterJoin,
              onChanged: (v) => setState(() => _saveAfterJoin = v ?? false),
              title: const Text('Save this chat'),
              subtitle: const Text('Reconnect easily after restart'),
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
            ),
            const SizedBox(height: 8),
            FilledButton.tonalIcon(
              onPressed: _joining
                  ? () async {
                      String? uuid;
                      if (_showBase64Input) {
                        final raw = _base64Ctrl.text.trim();
                        if (raw.isEmpty) return;
                        final data = QrShareData.fromBase64(raw);
                        if (data != null && data.type == 'room' && data.roomUUID != null) {
                          uuid = data.roomUUID;
                        } else {
                          final hex = raw.replaceAll('-', '');
                          if (hex.length == 32) uuid = hex;
                        }
                        if (uuid == null) {
                          setState(() => _decodeError = 'Could not parse');
                          return;
                        }
                        widget.roomsBloc.add(RoomsJoinRoom(uuid));
                      } else {
                        uuid = _uuidCtrl.text.trim();
                        if (uuid.isNotEmpty) {
                          widget.roomsBloc.add(RoomsJoinRoom(uuid));
                        }
                      }
                      if (uuid != null && _saveAfterJoin) {
                        await widget.onSaveChat?.call(uuid);
                      }
                      if (context.mounted) Navigator.of(context).pop();
                    }
                  : null,
              icon: const Icon(Icons.login),
              label: const Text('Join room'),
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            ),
          ],
        ),
      ),
    );
  }
}

class _Divider extends StatelessWidget {
  const _Divider();
  @override
  Widget build(BuildContext context) => const Row(children: [
    Expanded(child: Divider()),
    Padding(
      padding: EdgeInsets.symmetric(horizontal: 12),
      child: Text('or'),
    ),
    Expanded(child: Divider()),
  ]);
}
