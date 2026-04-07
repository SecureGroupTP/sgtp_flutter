import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:sgtp_flutter/core/app_theme.dart';
import 'package:sgtp_flutter/core/widgets/app_bottom_sheet.dart';
import 'package:sgtp_flutter/core/qr_data.dart';
import 'package:sgtp_flutter/features/messaging/application/viewmodels/chat/chat_bloc.dart';
import 'package:sgtp_flutter/features/messaging/application/viewmodels/chat/chat_event.dart';
import 'package:sgtp_flutter/features/messaging/application/viewmodels/chat/chat_state.dart';
import 'package:sgtp_flutter/features/messaging/application/viewmodels/rooms/rooms_bloc.dart';
import 'package:sgtp_flutter/features/messaging/application/viewmodels/rooms/rooms_event.dart';
import 'package:sgtp_flutter/features/messaging/application/viewmodels/rooms/rooms_state.dart';
import 'package:sgtp_flutter/features/settings/presentation/widgets/pretty_qr_share_panel.dart';
import 'package:sgtp_flutter/features/messaging/presentation/widgets/qr_scanner_dialog.dart';
import 'package:sgtp_flutter/features/messaging/presentation/widgets/room_avatar.dart';
import 'package:sgtp_flutter/features/messaging/presentation/widgets/room_status_dot.dart';
import 'package:sgtp_flutter/features/messaging/presentation/pages/chat_page.dart';
import 'package:sgtp_flutter/features/messaging/application/models/messaging_models.dart';
import 'package:sgtp_flutter/features/setup/application/models/setup_models.dart';
import 'package:sgtp_flutter/features/settings/application/services/settings_management_service.dart';
import 'package:sgtp_flutter/features/setup/domain/entities/node.dart';

bool get _isDesktop =>
    !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);

// ─────────────────────────────────────────────────────────────────────────────
// Page
// ─────────────────────────────────────────────────────────────────────────────

class RoomsPage extends StatefulWidget {
  final String accountId;
  final String serverAddress;
  const RoomsPage({
    super.key,
    required this.accountId,
    required this.serverAddress,
  });

  @override
  State<RoomsPage> createState() => RoomsPageState();
}

class RoomsPageState extends State<RoomsPage> {
  @override
  void initState() {
    super.initState();
    context.read<RoomsBloc>().add(const RoomsLoadStoredChats());
  }

  @override
  void didUpdateWidget(covariant RoomsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.accountId != widget.accountId ||
        oldWidget.serverAddress != widget.serverAddress) {
      context.read<RoomsBloc>().add(const RoomsLoadStoredChats());
    }
  }

  String _serverKey(String raw) {
    return raw
        .trim()
        .replaceAll(RegExp(r'^https?://', caseSensitive: false), '')
        .replaceAll(RegExp(r'^wss?://', caseSensitive: false), '')
        .toLowerCase();
  }

  String _chatKey(String uuid, String serverAddress) {
    return '$uuid@${_serverKey(serverAddress)}';
  }

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<RoomsBloc, RoomsState>(
      listener: (context, state) {
        context.read<RoomsBloc>().add(const RoomsSyncStoredChats());
        if (state.error != null) {
          ScaffoldMessenger.of(context)
            ..hideCurrentSnackBar()
            ..showSnackBar(SnackBar(content: Text(state.error!)));
        }
      },
      builder: (context, state) {
        final statuses =
            state.rooms.map((r) => r.chatBloc.state.status).toList();
        return Scaffold(
          backgroundColor: AppColors.bgMain,
          appBar: RoomsAppBar(
            statuses: statuses,
          ),
          body: _buildBody(context, state),
        );
      },
    );
  }

  Widget _buildBody(BuildContext context, RoomsState state) {
    final activeKeys =
        state.rooms.map((r) => _chatKey(r.roomUUID, r.serverAddress)).toSet();
    final storedNotActive = state.storedChats
        .where((c) => !activeKeys.contains(_chatKey(c.uuid, c.serverAddress)))
        .toList();
    final hasAnything = state.rooms.isNotEmpty || storedNotActive.isNotEmpty;

    if (!hasAnything) return const _EmptyState();

    return ListView(
      // Extra bottom padding so last item isn't hidden under FAB + nav bar.
      padding: const EdgeInsets.only(top: 4, bottom: 100),
      children: [
        // ── Active rooms ─────────────────────────────────────────────────
        ...state.rooms.map((entry) => ActiveRoomTile(
              entry: entry,
              onTap: () => _openRoom(context, entry),
              onReconnect: () => entry.chatBloc.add(const ChatReconnect()),
              onRemove: () => context
                  .read<RoomsBloc>()
                  .add(RoomsRemoveRoom(entry.roomUUID)),
            )),

        // ── Stored chats (not currently joined) ──────────────────────────
        if (storedNotActive.isNotEmpty) ...[
          const _SectionHeader(title: 'Stored Chats'),
          ...storedNotActive.map((chat) => SavedChatTile(
                uuid: chat.uuid,
                metadata: chat,
                onOpen: () => _openStoredChatPreview(context, chat),
                onRemove: () => context.read<RoomsBloc>().add(
                    RoomsDeleteStoredChat(chat.uuid,
                        serverAddress: chat.serverAddress)),
              )),
        ],
      ],
    );
  }

  void _openStoredChatPreview(BuildContext context, ChatMetadata metadata) {
    final roomsBloc = context.read<RoomsBloc>();
    final existing = _findRoomEntryByIdentity(
      roomsBloc.state,
      roomUUID: metadata.uuid,
      serverAddress: metadata.serverAddress,
    );
    if (existing != null) {
      _openRoom(context, existing);
      return;
    }

    StreamSubscription<RoomsState>? sub;
    sub = roomsBloc.stream.listen((state) {
      final created = _findRoomEntryByIdentity(
        state,
        roomUUID: metadata.uuid,
        serverAddress: metadata.serverAddress,
      );
      if (created != null) {
        sub?.cancel();
        if (!mounted) return;
        _openRoom(context, created);
      }
    });
    Future<void>.delayed(const Duration(seconds: 5), () {
      sub?.cancel();
    });

    roomsBloc.add(RoomsJoinRoom(
      metadata.uuid,
      serverAddress: metadata.serverAddress,
      openOffline: true,
    ));
  }

  void openRoomByUuid(
    String roomUUIDHex, {
    String? serverAddress,
    bool openOffline = true,
  }) {
    final roomsBloc = context.read<RoomsBloc>();
    final effectiveServer = (serverAddress ?? widget.serverAddress).trim();
    final existing = _findRoomEntryByIdentity(
      roomsBloc.state,
      roomUUID: roomUUIDHex,
      serverAddress: effectiveServer,
    );
    if (existing != null) {
      _openRoom(context, existing);
      return;
    }

    StreamSubscription<RoomsState>? sub;
    sub = roomsBloc.stream.listen((state) {
      final created = _findRoomEntryByIdentity(
        state,
        roomUUID: roomUUIDHex,
        serverAddress: effectiveServer,
      );
      if (created != null) {
        sub?.cancel();
        if (!mounted) return;
        _openRoom(context, created);
      }
    });
    Future<void>.delayed(const Duration(seconds: 5), () {
      sub?.cancel();
    });

    roomsBloc.add(
      RoomsJoinRoom(
        roomUUIDHex,
        serverAddress: effectiveServer,
        openOffline: openOffline,
      ),
    );
  }

  RoomEntry? _findRoomEntryByIdentity(
    RoomsState state, {
    required String roomUUID,
    required String serverAddress,
  }) {
    final targetUuid = roomUUID.trim().toLowerCase();
    final targetServer = _serverKey(serverAddress);
    for (final room in state.rooms) {
      if (room.roomUUID.trim().toLowerCase() == targetUuid &&
          _serverKey(room.serverAddress) == targetServer) {
        return room;
      }
    }
    return null;
  }

  void _openRoom(BuildContext context, RoomEntry entry) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => BlocProvider.value(
        value: entry.chatBloc,
        child: ChatPage(accountId: widget.accountId),
      ),
    ));
  }

  void showAddSheet() {
    showAppBottomSheet<void>(
      context,
      builder: (_) => _AddRoomSheet(
        roomsBloc: context.read<RoomsBloc>(),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// AppBar
// ─────────────────────────────────────────────────────────────────────────────

/// Custom AppBar with title + server address + global status dot.
class RoomsAppBar extends StatelessWidget implements PreferredSizeWidget {
  final List<ChatStatus> statuses;

  const RoomsAppBar({
    super.key,
    required this.statuses,
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
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Text(
                        'SGTP Chat',
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w600,
                          letterSpacing: -0.5,
                          color: AppColors.textPrimary,
                        ),
                      ),
                    ],
                  ),
                ),
                GlobalStatusDot(statuses: statuses),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Active room tile
// ─────────────────────────────────────────────────────────────────────────────

class ActiveRoomTile extends StatelessWidget {
  final RoomEntry entry;
  final VoidCallback onTap;
  final VoidCallback onReconnect;
  final VoidCallback onRemove;

  const ActiveRoomTile({
    super.key,
    required this.entry,
    required this.onTap,
    required this.onReconnect,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<ChatBloc, ChatState>(
      bloc: entry.chatBloc,
      builder: (context, chatState) {
        final isOffline = chatState.status == ChatStatus.disconnected ||
            chatState.status == ChatStatus.error;
        final name =
            chatState.chatName != 'Chat' ? chatState.chatName : entry.label;

        return _ChatTile(
          onTap: onTap,
          leading: RoomAvatar(
            avatarBytes: chatState.chatAvatarBytes,
            fallbackIcon: Icons.tag,
          ),
          title: name,
          subtitle: Row(
            children: [
              RoomStatusDot(status: chatState.status),
              const SizedBox(width: 6),
              Text(
                _statusText(chatState.status),
                style: const TextStyle(
                    fontSize: 13, color: AppColors.textSecondary),
              ),
              if (chatState.peerUUIDs.isNotEmpty) ...[
                const SizedBox(width: 6),
                Text(
                  '· ${chatState.peerUUIDs.length} peer${chatState.peerUUIDs.length == 1 ? '' : 's'}',
                  style: const TextStyle(
                      fontSize: 13, color: AppColors.textSecondary),
                ),
              ],
            ],
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isOffline) _ReconnectButton(onPressed: onReconnect),
              _ActiveRoomMoreButton(
                entry: entry,
                chatState: chatState,
                onTap: onTap,
                onRemove: onRemove,
              ),
            ],
          ),
        );
      },
    );
  }

  String _statusText(ChatStatus status) => switch (status) {
        ChatStatus.ready => 'Ready',
        ChatStatus.connecting => 'Connecting…',
        ChatStatus.handshaking => 'Handshaking…',
        ChatStatus.error => 'Error',
        ChatStatus.disconnected => 'Disconnected',
      };
}

// Wires up _MoreButton's selection for ActiveRoomTile — done via a separate
// stateless wrapper that has access to the needed callbacks.
class _ActiveRoomMoreButton extends StatelessWidget {
  final RoomEntry entry;
  final ChatState chatState;
  final VoidCallback onTap;
  final VoidCallback onRemove;

  const _ActiveRoomMoreButton({
    required this.entry,
    required this.chatState,
    required this.onTap,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<_RoomAction>(
      icon:
          const Icon(Icons.more_vert, size: 22, color: AppColors.textSecondary),
      color: AppColors.bgSurface,
      onSelected: (action) => _handle(context, action),
      itemBuilder: (_) => [
        const PopupMenuItem(
          value: _RoomAction.open,
          child: _MenuItem(icon: Icons.open_in_new, label: 'Open'),
        ),
        const PopupMenuItem(
          value: _RoomAction.copyUUID,
          child: _MenuItem(icon: Icons.copy_outlined, label: 'Copy UUID'),
        ),
        const PopupMenuItem(
          value: _RoomAction.shareQR,
          child: _MenuItem(icon: Icons.qr_code_2_outlined, label: 'Share QR'),
        ),
        const PopupMenuDivider(),
        const PopupMenuItem(
          value: _RoomAction.remove,
          child: _MenuItem(
              icon: Icons.delete_outline,
              label: 'Remove',
              color: AppColors.statusRed),
        ),
      ],
    );
  }

  void _handle(BuildContext context, _RoomAction action) {
    switch (action) {
      case _RoomAction.open:
        onTap();
      case _RoomAction.copyUUID:
        Clipboard.setData(ClipboardData(text: entry.roomUUID));
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Room UUID copied')));
      case _RoomAction.shareQR:
        final qrData = QrShareData(
          type: 'room',
          roomUUID: entry.roomUUID,
          timestamp: DateTime.now().millisecondsSinceEpoch,
        );
        showAppBottomSheet<void>(
          context,
          builder: (_) => SafeArea(
            child: PrettyQrSharePanel(
              data: qrData,
              title: 'Share Room',
              description: chatState.chatName != 'Chat'
                  ? chatState.chatName
                  : entry.label,
              copyMessage: 'Room hex copied',
              exportName:
                  'room_${entry.roomUUID.substring(0, 8).toLowerCase()}.png',
            ),
          ),
        );
      case _RoomAction.remove:
        onRemove();
    }
  }
}

enum _RoomAction { open, copyUUID, shareQR, remove }

// ─────────────────────────────────────────────────────────────────────────────
// Saved chat tile
// ─────────────────────────────────────────────────────────────────────────────

class SavedChatTile extends StatelessWidget {
  final String uuid;
  final ChatMetadata? metadata;
  final VoidCallback onOpen;
  final VoidCallback onRemove;

  const SavedChatTile({
    super.key,
    required this.uuid,
    this.metadata,
    required this.onOpen,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final hasMetadataName = metadata != null && metadata!.name.isNotEmpty;
    final title = hasMetadataName ? metadata!.name : '${uuid.substring(0, 8)}…';
    final subtitle = metadata?.updatedAt != null
        ? 'Stored · ${_formatSavedChatLastActive(metadata!.updatedAt)}'
        : 'Stored · tap to open';
    return _ChatTile(
      onTap: onOpen,
      leading: metadata?.avatarBytes != null
          ? RoomAvatar(
              avatarBytes: metadata!.avatarBytes,
              fallbackIcon: Icons.bookmark_outlined,
            )
          : const SavedChatAvatar(),
      title: title,
      titleStyle: hasMetadataName
          ? null
          : const TextStyle(
              fontFamily: 'monospace',
              fontSize: 14,
              color: AppColors.textPrimary,
            ),
      subtitle: Text(
        subtitle,
        style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _IconAction(
            icon: Icons.copy_outlined,
            onPressed: () {
              Clipboard.setData(ClipboardData(text: uuid));
              ScaffoldMessenger.of(context)
                  .showSnackBar(const SnackBar(content: Text('UUID copied')));
            },
          ),
          _IconAction(
            icon: Icons.delete_outline,
            color: AppColors.statusRed,
            onPressed: onRemove,
          ),
        ],
      ),
    );
  }
}

String _formatSavedChatLastActive(DateTime updatedAt) {
  final local = updatedAt.toLocal();
  final now = DateTime.now();
  final sameDay = now.year == local.year &&
      now.month == local.month &&
      now.day == local.day;
  final yesterday = now.subtract(const Duration(days: 1));
  final sameAsYesterday = yesterday.year == local.year &&
      yesterday.month == local.month &&
      yesterday.day == local.day;
  final hh = local.hour.toString().padLeft(2, '0');
  final mm = local.minute.toString().padLeft(2, '0');
  if (sameDay) {
    return 'last active today at $hh:$mm';
  }
  if (sameAsYesterday) {
    return 'last active yesterday at $hh:$mm';
  }
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  final month = months[local.month - 1];
  if (now.year == local.year) {
    return 'last active ${local.day} $month at $hh:$mm';
  }
  return 'last active ${local.day} $month ${local.year}';
}

// ─────────────────────────────────────────────────────────────────────────────
// Shared building blocks
// ─────────────────────────────────────────────────────────────────────────────

/// Base pressable tile with consistent 14 × 20 padding and ink splash.
class _ChatTile extends StatelessWidget {
  final VoidCallback onTap;
  final Widget leading;
  final String title;
  final TextStyle? titleStyle;
  final Widget subtitle;
  final Widget? trailing;

  const _ChatTile({
    required this.onTap,
    required this.leading,
    required this.title,
    this.titleStyle,
    required this.subtitle,
    this.trailing,
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
            leading,
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    overflow: TextOverflow.ellipsis,
                    style: titleStyle ??
                        const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                          color: AppColors.textPrimary,
                        ),
                  ),
                  const SizedBox(height: 4),
                  subtitle,
                ],
              ),
            ),
            if (trailing != null) ...[
              const SizedBox(width: 8),
              trailing!,
            ],
          ],
        ),
      ),
    );
  }
}

/// "SAVED CHATS" style section header with a trailing divider line.
class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader({required this.title});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 8),
      child: Row(
        children: [
          Text(
            title.toUpperCase(),
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: AppColors.textSecondary,
              letterSpacing: 1,
            ),
          ),
          const SizedBox(width: 12),
          const Expanded(child: Divider(color: AppColors.border, height: 1)),
        ],
      ),
    );
  }
}

/// Pill-shaped "Reconnect" button.
class _ReconnectButton extends StatelessWidget {
  final VoidCallback onPressed;
  const _ReconnectButton({required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onPressed,
      child: Container(
        margin: const EdgeInsets.only(right: 10),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.white.withAlpha(25), // rgba(255,255,255,0.1)
          borderRadius: BorderRadius.circular(14),
        ),
        child: const Text(
          'Reconnect',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w500,
            color: AppColors.textPrimary,
          ),
        ),
      ),
    );
  }
}

/// Tiny icon button used in stored chat trailing area.
class _IconAction extends StatelessWidget {
  final IconData icon;
  final Color color;
  final VoidCallback onPressed;

  const _IconAction({
    required this.icon,
    this.color = AppColors.textSecondary,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onPressed,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Icon(icon, size: 22, color: color),
      ),
    );
  }
}

/// Menu item row used inside [PopupMenuButton].
class _MenuItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;

  const _MenuItem({
    required this.icon,
    required this.label,
    this.color = AppColors.textPrimary,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 20, color: color),
        const SizedBox(width: 12),
        Text(label, style: TextStyle(color: color)),
      ],
    );
  }
}

/// White squircle FAB.
/// Full-screen empty state.
class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.forum_outlined,
                size: 72, color: AppColors.textSecondary),
            SizedBox(height: 16),
            Text(
              'No rooms yet',
              style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w500,
                  color: AppColors.textPrimary),
            ),
            SizedBox(height: 8),
            Text(
              'Tap + to create a new room\nor join an existing one by UUID.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, color: AppColors.textSecondary),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Add room bottom sheet
// ─────────────────────────────────────────────────────────────────────────────

class _AddRoomSheet extends StatefulWidget {
  final RoomsBloc roomsBloc;
  const _AddRoomSheet({required this.roomsBloc});

  @override
  State<_AddRoomSheet> createState() => _AddRoomSheetState();
}

class _AddRoomSheetState extends State<_AddRoomSheet> {
  final _uuidCtrl = TextEditingController();
  final _shareHexCtrl = TextEditingController();
  bool _joining = false;
  bool _showBase64Input = false;
  String? _decodeError;

  late final SettingsManagementService _settingsRepo;
  List<NodeConfig> _nodes = const [];
  String? _selectedNodeId;
  bool _nodesLoading = true;

  @override
  void dispose() {
    _uuidCtrl.dispose();
    _shareHexCtrl.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _settingsRepo = context.read<SettingsManagementService>();
    _loadNodes();
  }

  Future<void> _loadNodes() async {
    final nodes = await _settingsRepo.loadNodes();
    final preferredNode = await _settingsRepo.loadPreferredNode();
    if (!mounted) return;
    setState(() {
      _nodes = nodes;
      _selectedNodeId =
          preferredNode?.id ?? (nodes.isNotEmpty ? nodes.first.id : null);
      _nodesLoading = false;
    });
  }

  String? get _selectedChatServer {
    return _selectedNode?.chatAddress;
  }

  NodeConfig? get _selectedNode {
    if (_selectedNodeId == null) return null;
    return _nodes.where((n) => n.id == _selectedNodeId).firstOrNull;
  }

  NodeConfig? _nodeByServerAddress(String? serverAddress) {
    final target = (serverAddress ?? '').trim().toLowerCase();
    if (target.isEmpty) return null;
    for (final n in _nodes) {
      if (n.chatAddress.trim().toLowerCase() == target) return n;
    }
    return null;
  }

  void _handleQrScanned(QrShareData data) {
    if (data.type == 'room' && data.roomUUID != null) {
      final targetServer = data.serverAddress ?? _selectedChatServer;
      final targetNode = _nodeByServerAddress(targetServer) ?? _selectedNode;
      widget.roomsBloc.add(RoomsJoinRoom(
        data.roomUUID!,
        serverAddress: targetServer,
        transport: targetNode?.transport,
        useTls: targetNode?.useTls,
      ));
      Navigator.of(context).pop();
    } else {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Invalid room QR code')));
    }
  }

  void _joinFromInput() async {
    String? uuid;
    String? serverAddress = _selectedChatServer;
    NodeConfig? targetNode = _selectedNode;
    if (_showBase64Input) {
      final raw = _shareHexCtrl.text.trim();
      if (raw.isEmpty) return;
      final data = QrShareData.parse(raw);
      if (data != null && data.type == 'room' && data.roomUUID != null) {
        uuid = data.roomUUID;
        serverAddress = data.serverAddress ?? serverAddress;
        targetNode = _nodeByServerAddress(serverAddress) ?? targetNode;
      } else {
        final hex = raw.replaceAll('-', '');
        if (hex.length == 32) uuid = hex;
      }
      if (uuid == null) {
        setState(() => _decodeError =
            'Could not parse — paste valid room hex or 32-char UUID');
        return;
      }
    } else {
      uuid = _uuidCtrl.text.trim();
      if (uuid.isEmpty) return;
    }
    widget.roomsBloc.add(RoomsJoinRoom(
      uuid,
      serverAddress: serverAddress,
      transport: targetNode?.transport,
      useTls: targetNode?.useTls,
    ));
    widget.roomsBloc.add(RoomsUpsertChat(uuid, serverAddress: serverAddress));
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
          24, 24, 24, MediaQuery.of(context).viewInsets.bottom + 24),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Add room',
              style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary),
            ),
            const SizedBox(height: 24),

            // Node picker
            _NodePicker(
              isLoading: _nodesLoading,
              nodes: _nodes,
              selectedId: _selectedNodeId,
              onChanged: (id) => setState(() => _selectedNodeId = id),
            ),
            const SizedBox(height: 16),

            // Create new
            AppSheetButton(
              label: 'Create new room',
              icon: Icons.add_circle_outline,
              onTap: () {
                widget.roomsBloc.add(
                  RoomsCreateRoom(
                    serverAddress: _selectedChatServer,
                    transport: _selectedNode?.transport,
                    useTls: _selectedNode?.useTls,
                  ),
                );
                Navigator.of(context).pop();
              },
            ),
            const SizedBox(height: 16),
            const AppSheetOrDivider(),
            const SizedBox(height: 16),

            // Scan QR — mobile only
            if (!_isDesktop) ...[
              AppSheetButton(
                label: 'Scan QR code',
                icon: Icons.qr_code_scanner,
                secondary: true,
                onTap: () async {
                  final data = await Navigator.push<QrShareData>(
                    context,
                    MaterialPageRoute(
                      fullscreenDialog: true,
                      builder: (_) => const QrScannerDialog(),
                    ),
                  );
                  if (data != null) _handleQrScanned(data);
                },
              ),
              const SizedBox(height: 12),
              const AppSheetOrDivider(),
              const SizedBox(height: 12),
            ],

            // UUID / room-share hex input
            if (!_showBase64Input) ...[
              _DarkTextField(
                controller: _uuidCtrl,
                label: 'Room UUID',
                hint: '32 hex chars (without dashes)',
                prefixIcon: Icons.vpn_key_outlined,
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
                child: const Text('Or paste room share hex',
                    style: TextStyle(color: AppColors.textSecondary)),
              ),
            ] else ...[
              _DarkTextField(
                controller: _shareHexCtrl,
                label: 'Room Share Hex or UUID',
                hint: 'Paste room share hex or 32-char UUID here',
                prefixIcon: Icons.vpn_key_outlined,
                maxLines: 3,
                autofocus: true,
                errorText: _decodeError,
                onChanged: (v) => setState(() {
                  _joining = v.trim().isNotEmpty;
                  _decodeError = null;
                }),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: () => setState(() {
                  _showBase64Input = false;
                  _shareHexCtrl.clear();
                  _decodeError = null;
                }),
                child: const Text('Back to UUID input',
                    style: TextStyle(color: AppColors.textSecondary)),
              ),
            ],

            const SizedBox(height: 8),
            AppSheetButton(
              label: 'Join room',
              icon: Icons.login,
              onTap: _joining ? _joinFromInput : null,
            ),
          ],
        ),
      ),
    );
  }
}

class _NodePicker extends StatelessWidget {
  final bool isLoading;
  final List<NodeConfig> nodes;
  final String? selectedId;
  final ValueChanged<String?> onChanged;

  const _NodePicker({
    required this.isLoading,
    required this.nodes,
    required this.selectedId,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    if (isLoading) {
      return Container(
        height: 52,
        decoration: BoxDecoration(
          color: Colors.white.withAlpha(14),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white.withAlpha(18)),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: const Row(
          children: [
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(width: 10),
            Text(
              'Loading nodes…',
              style: TextStyle(fontSize: 14, color: AppColors.textSecondary),
            ),
          ],
        ),
      );
    }

    if (nodes.isEmpty) {
      return Container(
        height: 52,
        decoration: BoxDecoration(
          color: Colors.white.withAlpha(14),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white.withAlpha(18)),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        alignment: Alignment.centerLeft,
        child: const Text(
          'No nodes configured',
          style: TextStyle(fontSize: 14, color: AppColors.textSecondary),
        ),
      );
    }

    final value = (selectedId != null && nodes.any((n) => n.id == selectedId))
        ? selectedId
        : nodes.first.id;

    return Container(
      height: 52,
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(14),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withAlpha(18)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: value,
          isExpanded: true,
          dropdownColor: AppColors.bgSurface,
          iconEnabledColor: AppColors.textSecondary,
          onChanged: onChanged,
          items: nodes
              .map(
                (n) => DropdownMenuItem(
                  value: n.id,
                  child: Text(
                    n.name,
                    style: const TextStyle(
                        fontSize: 14, color: AppColors.textPrimary),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              )
              .toList(),
        ),
      ),
    );
  }
}

/// Text field styled for the dark sheet.
class _DarkTextField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final String hint;
  final IconData prefixIcon;
  final int maxLines;
  final bool autofocus;
  final String? errorText;
  final ValueChanged<String>? onChanged;

  const _DarkTextField({
    required this.controller,
    required this.label,
    required this.hint,
    required this.prefixIcon,
    this.maxLines = 1,
    this.autofocus = false,
    this.errorText,
    this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      maxLines: maxLines,
      autofocus: autofocus,
      style: const TextStyle(color: AppColors.textPrimary),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(color: AppColors.textSecondary),
        hintText: hint,
        hintStyle: const TextStyle(color: AppColors.textSecondary),
        prefixIcon: Icon(prefixIcon, color: AppColors.textSecondary),
        errorText: errorText,
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
      ),
      onChanged: onChanged,
    );
  }
}
