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

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<RoomsBloc, RoomsState>(
      listenWhen: (previous, current) =>
          previous.error != current.error ||
          _syncSignature(previous) != _syncSignature(current),
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
    if (state.rooms.isEmpty) {
      // Stored chats are auto-connected by RoomsBloc; avoid showing an
      // "offline cache" section in UI.
      if (state.storedChats.isNotEmpty) {
        return const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        );
      }
      return const _EmptyState();
    }

    return ListView(
      // Extra bottom padding so last item isn't hidden under FAB + nav bar.
      padding: const EdgeInsets.only(top: 4, bottom: 100),
      children: [
        // ── Active rooms ─────────────────────────────────────────────────
        ...state.rooms.map((entry) => ActiveRoomTile(
              entry: entry,
              onTap: () => _openRoom(entry),
              onRemove: () => context.read<RoomsBloc>().add(RoomsRemoveRoom(
                  entry.roomUUID,
                  serverAddress: entry.serverAddress)),
            )),
      ],
    );
  }

  void openRoomByUuid(
    String roomUUIDHex, {
    String? serverAddress,
    bool isDirectMessage = false,
    bool bootstrapDirectRoom = false,
    String? directPeerPublicKeyHex,
  }) {
    final roomsBloc = context.read<RoomsBloc>();
    final effectiveServer = (serverAddress ?? widget.serverAddress).trim();
    final existing = _findRoomEntryByIdentity(
      roomsBloc.state,
      roomUUID: roomUUIDHex,
      serverAddress: effectiveServer,
    );
    if (existing != null) {
      _openRoom(existing);
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
        _openRoom(created);
      }
    });
    Future<void>.delayed(const Duration(seconds: 5), () {
      sub?.cancel();
    });

    roomsBloc.add(
      RoomsJoinRoom(
        roomUUIDHex,
        serverAddress: effectiveServer,
        isDirectMessage: isDirectMessage,
        bootstrapDirectRoom: bootstrapDirectRoom,
        directPeerPublicKeyHex: directPeerPublicKeyHex,
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

  void _openRoom(RoomEntry entry) {
    if (!mounted) return;
    final status = entry.chatBloc.state.status;
    final errorMessage = entry.chatBloc.state.errorMessage;
    entry.chatBloc.add(const ChatMarkAllRead());
    if (status == ChatStatus.disconnected ||
        (status == ChatStatus.error &&
            !_isNonRecoverableConnectionError(errorMessage))) {
      entry.chatBloc.add(const ChatReconnect());
    }
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => BlocProvider.value(
        value: entry.chatBloc,
        child: ChatPage(accountId: widget.accountId),
      ),
    ));
  }

  bool _isNonRecoverableConnectionError(String? error) {
    final message = error ?? '';
    return message.contains('MLS welcome is missing') ||
        message.contains('MLS welcome failed') ||
        message.contains('Waiting for chat invitation');
  }

  void showAddSheet() {
    showAppBottomSheet<void>(
      context,
      builder: (_) => _AddRoomSheet(
        roomsBloc: context.read<RoomsBloc>(),
        defaultServerAddress: widget.serverAddress,
      ),
    );
  }

  String _syncSignature(RoomsState state) {
    return state.rooms.map((room) {
      final chat = room.chatBloc.state;
      final avatarSize = chat.chatAvatarBytes?.length ?? 0;
      return [
        room.roomUUID,
        _serverKey(room.serverAddress),
        chat.status.name,
        chat.chatName,
        '$avatarSize',
        '${chat.isDirectChat}',
      ].join('|');
    }).join('||');
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
  final VoidCallback onRemove;

  const ActiveRoomTile({
    super.key,
    required this.entry,
    required this.onTap,
    required this.onRemove,
  });

  String _previewText(ChatState state) {
    ChatMessage? last;
    for (var i = state.messages.length - 1; i >= 0; i--) {
      final m = state.messages[i];
      if (m.type == MessageType.system ||
          m.type == MessageType.messageRead ||
          m.type == MessageType.reaction ||
          m.type == MessageType.viewed) {
        continue;
      }
      last = m;
      break;
    }
    if (last == null) {
      return 'No messages yet';
    }

    final sender = last.isFromMe
        ? 'You'
        : (state.peerNicknames[last.senderUUID] ??
            state.peerNicknamesHistory[last.senderUUID] ??
            (last.senderUUID.length >= 8
                ? last.senderUUID.substring(0, 8)
                : last.senderUUID));
    final body = switch (last.type) {
      MessageType.text =>
        last.content.trim().isEmpty ? 'Message' : last.content,
      MessageType.image => 'Photo',
      MessageType.gif => 'GIF',
      MessageType.video => 'Video',
      MessageType.voice => 'Voice message',
      MessageType.videoNote => 'Video note',
      _ => 'Message',
    };

    return '$sender: $body';
  }

  void _showActions(BuildContext context, ChatState chatState) {
    showAppBottomSheet<void>(
      context,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.open_in_new),
              title: const Text('Open'),
              onTap: () {
                Navigator.pop(context);
                onTap();
              },
            ),
            ListTile(
              leading: const Icon(Icons.qr_code_2_outlined),
              title: const Text('Share QR'),
              onTap: () {
                Navigator.pop(context);
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
              },
            ),
            const Divider(height: 1),
            ListTile(
              leading:
                  const Icon(Icons.delete_outline, color: AppColors.statusRed),
              title: const Text('Remove',
                  style: TextStyle(color: AppColors.statusRed)),
              onTap: () {
                Navigator.pop(context);
                onRemove();
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<ChatBloc, ChatState>(
      bloc: entry.chatBloc,
      builder: (context, chatState) {
        final name =
            chatState.chatName != 'Chat' ? chatState.chatName : entry.label;
        final preview = _previewText(chatState);

        return _ChatTile(
          onTap: onTap,
          onLongPress: () => _showActions(context, chatState),
          onSecondaryTap: () => _showActions(context, chatState),
          leading: RoomAvatar(
            avatarBytes: chatState.chatAvatarBytes,
            fallbackIcon: Icons.tag,
            fallbackName: name,
          ),
          title: name,
          subtitle: Text(
            preview,
            overflow: TextOverflow.ellipsis,
            style:
                const TextStyle(fontSize: 13, color: AppColors.textSecondary),
          ),
          trailing: chatState.unreadCount > 0
              ? _UnreadBadge(count: chatState.unreadCount)
              : null,
        );
      },
    );
  }
}

class _UnreadBadge extends StatelessWidget {
  final int count;
  const _UnreadBadge({required this.count});

  @override
  Widget build(BuildContext context) {
    final text = count > 99 ? '99' : '$count';
    return Container(
      width: 24,
      height: 24,
      decoration: BoxDecoration(
        color: const Color(0xFFF5F5F5),
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: Text(text,
          style: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w800,
            color: Color(0xFF141417),
          )),
    );
  }
}

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
        ? 'Saved locally · ${_formatSavedChatLastActive(metadata!.updatedAt)}'
        : 'Saved locally · tap to open';
    return _ChatTile(
      onTap: onOpen,
      leading: metadata?.avatarBytes != null
          ? RoomAvatar(
              avatarBytes: metadata!.avatarBytes,
              fallbackIcon: Icons.bookmark_outlined,
              fallbackName: title,
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
  final VoidCallback? onLongPress;
  final VoidCallback? onSecondaryTap;
  final Widget leading;
  final String title;
  final TextStyle? titleStyle;
  final Widget subtitle;
  final Widget? trailing;

  const _ChatTile({
    required this.onTap,
    this.onLongPress,
    this.onSecondaryTap,
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
      onLongPress: onLongPress,
      onSecondaryTap: onSecondaryTap,
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
  final String defaultServerAddress;
  const _AddRoomSheet({
    required this.roomsBloc,
    required this.defaultServerAddress,
  });

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
      final target = widget.defaultServerAddress.trim().toLowerCase();
      final matchedByAddress = nodes
          .where((n) =>
              n.chatAddress.trim().toLowerCase() == target ||
              n.discoveryAddress.trim().toLowerCase() == target)
          .firstOrNull;
      _selectedNodeId = matchedByAddress?.id ??
          preferredNode?.id ??
          (nodes.isNotEmpty ? nodes.first.id : null);
    });
  }

  String? get _selectedChatServer {
    final explicit = widget.defaultServerAddress.trim();
    if (explicit.isNotEmpty) return explicit;
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
      if (n.chatAddress.trim().toLowerCase() == target ||
          n.discoveryAddress.trim().toLowerCase() == target) {
        return n;
      }
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
