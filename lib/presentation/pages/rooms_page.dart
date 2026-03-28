import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../blocs/chat/chat_bloc.dart';
import '../blocs/chat/chat_state.dart';
import '../blocs/rooms/rooms_bloc.dart';
import '../blocs/rooms/rooms_event.dart';
import '../blocs/rooms/rooms_state.dart';
import 'chat_page.dart';

class RoomsPage extends StatelessWidget {
  const RoomsPage({super.key});

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

  // ── AppBar ────────────────────────────────────────────────────────────────

  PreferredSizeWidget _buildAppBar(BuildContext context, RoomsState state) {
    final theme = Theme.of(context);

    // Compute aggregate connection status across all rooms
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
              width: 12,
              height: 12,
              decoration: BoxDecoration(
                color: dotColor,
                shape: BoxShape.circle,
              ),
            ),
          ),
        ),
      ],
    );
  }

  String _statusTooltip(List<ChatStatus> statuses) {
    if (statuses.isEmpty) return 'No active rooms';
    if (statuses.any((s) => s == ChatStatus.ready)) return 'Connected';
    if (statuses.any(
        (s) => s == ChatStatus.connecting || s == ChatStatus.handshaking)) {
      return 'Connecting…';
    }
    return 'Disconnected';
  }

  // ── Empty state ───────────────────────────────────────────────────────────

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
            Text(
              'No rooms yet',
              style: theme.textTheme.titleMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant),
            ),
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

  // ── Room list ─────────────────────────────────────────────────────────────

  Widget _buildRoomList(BuildContext context, RoomsState state) {
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: state.rooms.length,
      separatorBuilder: (_, __) => const Divider(height: 1, indent: 72),
      itemBuilder: (context, i) {
        final entry = state.rooms[i];
        return _RoomTile(
          entry: entry,
          onTap: () => _openRoom(context, entry),
          onRemove: () =>
              context.read<RoomsBloc>().add(RoomsRemoveRoom(entry.roomUUID)),
        );
      },
    );
  }

  // ── Navigation ────────────────────────────────────────────────────────────

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

  // ── FAB sheet ─────────────────────────────────────────────────────────────

  void _showAddSheet(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (sheetCtx) => _AddRoomSheet(roomsBloc: context.read<RoomsBloc>()),
    );
  }
}

// ── Room tile ──────────────────────────────────────────────────────────────

class _RoomTile extends StatelessWidget {
  final RoomEntry entry;
  final VoidCallback onTap;
  final VoidCallback onRemove;

  const _RoomTile({
    required this.entry,
    required this.onTap,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<ChatBloc, ChatState>(
      bloc: entry.chatBloc,
      builder: (context, chatState) {
        final statusColor = _statusColor(context, chatState.status);
        final statusText  = _statusText(chatState.status);

        return ListTile(
          leading: CircleAvatar(
            backgroundColor:
                Theme.of(context).colorScheme.secondaryContainer,
            child: Icon(Icons.meeting_room_outlined,
                color: Theme.of(context).colorScheme.onSecondaryContainer),
          ),
          title: Text(
            entry.label,
            style: const TextStyle(fontFamily: 'monospace'),
          ),
          subtitle: Row(
            children: [
              Container(
                width: 8,
                height: 8,
                margin: const EdgeInsets.only(right: 6, top: 1),
                decoration: BoxDecoration(
                  color: statusColor,
                  shape: BoxShape.circle,
                ),
              ),
              Text(statusText),
              if (chatState.peerUUIDs.isNotEmpty) ...[
                const SizedBox(width: 8),
                Text('· ${chatState.peerUUIDs.length} peer${chatState.peerUUIDs.length == 1 ? '' : 's'}',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant)),
              ],
            ],
          ),
          trailing: PopupMenuButton<_RoomAction>(
            icon: const Icon(Icons.more_vert),
            onSelected: (action) {
              switch (action) {
                case _RoomAction.copyUUID:
                  Clipboard.setData(ClipboardData(text: entry.roomUUID));
                  ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Room UUID copied')));
                case _RoomAction.remove:
                  onRemove();
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: _RoomAction.copyUUID,
                child: ListTile(
                  leading: Icon(Icons.copy),
                  title: Text('Copy UUID'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              PopupMenuDivider(),
              PopupMenuItem(
                value: _RoomAction.remove,
                child: ListTile(
                  leading: Icon(Icons.delete_outline),
                  title: Text('Remove'),
                  contentPadding: EdgeInsets.zero,
                ),
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

enum _RoomAction { copyUUID, remove }

// ── Add room bottom sheet ─────────────────────────────────────────────────

class _AddRoomSheet extends StatefulWidget {
  final RoomsBloc roomsBloc;
  const _AddRoomSheet({required this.roomsBloc});

  @override
  State<_AddRoomSheet> createState() => _AddRoomSheetState();
}

class _AddRoomSheetState extends State<_AddRoomSheet> {
  final _uuidCtrl = TextEditingController();
  bool _joining = false;

  @override
  void dispose() {
    _uuidCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(
          24, 24, 24, MediaQuery.of(context).viewInsets.bottom + 24),
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
          const Row(children: [
            Expanded(child: Divider()),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 12),
              child: Text('or'),
            ),
            Expanded(child: Divider()),
          ]),
          const SizedBox(height: 16),
          // Join by UUID
          TextField(
            controller: _uuidCtrl,
            decoration: const InputDecoration(
              labelText: 'Room UUID',
              hintText: '32 hex chars (without dashes)',
              prefixIcon: Icon(Icons.vpn_key_outlined),
              border: OutlineInputBorder(),
            ),
            onChanged: (v) => setState(() => _joining = v.trim().isNotEmpty),
          ),
          const SizedBox(height: 12),
          FilledButton.tonalIcon(
            onPressed: _joining
                ? () {
                    widget.roomsBloc
                        .add(RoomsJoinRoom(_uuidCtrl.text.trim()));
                    Navigator.of(context).pop();
                  }
                : null,
            icon: const Icon(Icons.login),
            label: const Text('Join room'),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
          ),
        ],
      ),
    );
  }
}
