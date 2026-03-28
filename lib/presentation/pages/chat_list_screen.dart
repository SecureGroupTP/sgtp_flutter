import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:image_picker/image_picker.dart';

import '../../domain/entities/chat_metadata.dart';
import '../blocs/chat_list/chat_list_bloc.dart';
import 'chat_metadata_edit_dialog.dart';

class ChatListScreen extends StatefulWidget {
  final VoidCallback? onChatSelected;

  const ChatListScreen({
    Key? key,
    this.onChatSelected,
  }) : super(key: key);

  @override
  State<ChatListScreen> createState() => _ChatListScreenState();
}

class _ChatListScreenState extends State<ChatListScreen> {
  @override
  void initState() {
    super.initState();
    // Load chats on first build
    context.read<ChatListBloc>().add(ChatListLoadChats());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Chats'),
        elevation: 0,
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _showCreateChatDialog(),
        tooltip: 'New Chat',
        child: const Icon(Icons.add),
      ),
      body: BlocBuilder<ChatListBloc, ChatListState>(
        builder: (context, state) {
          if (state.isLoading) {
            return const Center(child: CircularProgressIndicator());
          }

          if (state.hasError) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.error_outline, size: 48, color: Colors.grey),
                  const SizedBox(height: 16),
                  Text(state.errorMessage ?? 'Error loading chats'),
                  const SizedBox(height: 16),
                  ElevatedButton(
                    onPressed: () {
                      context.read<ChatListBloc>().add(ChatListLoadChats());
                    },
                    child: const Text('Retry'),
                  ),
                ],
              ),
            );
          }

          if (!state.hasChats) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.chat_bubble_outline, size: 64, color: Colors.grey),
                  const SizedBox(height: 16),
                  const Text(
                    'No chats yet',
                    style: TextStyle(fontSize: 18, color: Colors.grey),
                  ),
                  const SizedBox(height: 32),
                  ElevatedButton.icon(
                    onPressed: () => _showCreateChatDialog(),
                    icon: const Icon(Icons.add),
                    label: const Text('Create Chat'),
                  ),
                ],
              ),
            );
          }

          return ListView.builder(
            itemCount: state.chats.length,
            itemBuilder: (context, index) {
              final chat = state.chats[index];
              return _ChatListTile(
                chat: chat,
                onEdit: () => _showEditDialog(chat),
                onDelete: () => _showDeleteConfirm(chat),
                onTap: () {
                  context.read<ChatListBloc>().add(ChatListSelectChat(chat: chat));
                  widget.onChatSelected?.call();
                },
              );
            },
          );
        },
      ),
    );
  }

  void _showCreateChatDialog() {
    showDialog(
      context: context,
      builder: (context) {
        String chatName = 'My Chat';
        Uint8List? avatarBytes;

        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              title: const Text('Create New Chat'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Avatar preview
                    Center(
                      child: GestureDetector(
                        onTap: () => _pickAvatar(setState, (bytes) {
                          avatarBytes = bytes;
                        }),
                        child: CircleAvatar(
                          radius: 40,
                          backgroundImage: avatarBytes != null
                              ? MemoryImage(avatarBytes!)
                              : null,
                          child: avatarBytes == null
                              ? const Icon(Icons.camera_alt)
                              : null,
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    // Name field
                    TextField(
                      decoration: const InputDecoration(
                        labelText: 'Chat Name',
                        hintText: 'Enter chat name',
                      ),
                      onChanged: (value) {
                        chatName = value.isEmpty ? 'My Chat' : value;
                      },
                      controller: TextEditingController(text: chatName),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancel'),
                ),
                ElevatedButton(
                  onPressed: () {
                    context.read<ChatListBloc>().add(
                          ChatListCreateChat(
                            name: chatName,
                            avatarBytes: avatarBytes,
                          ),
                        );
                    Navigator.pop(context);
                  },
                  child: const Text('Create'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _showEditDialog(ChatMetadata chat) {
    showDialog(
      context: context,
      builder: (context) => ChatMetadataEditDialog(
        chat: chat,
        onSave: (name, avatar) {
          context.read<ChatListBloc>().add(
                ChatListUpdateChat(
                  uuid: chat.uuid,
                  newName: name,
                  newAvatarBytes: avatar,
                ),
              );
          Navigator.pop(context);
        },
      ),
    );
  }

  void _showDeleteConfirm(ChatMetadata chat) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Chat'),
        content: Text('Delete "${chat.name}" from your local storage?\n\nThis only removes it from your device.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              context.read<ChatListBloc>().add(ChatListDeleteChat(uuid: chat.uuid));
              Navigator.pop(context);
            },
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  Future<void> _pickAvatar(
    StateSetter setState,
    ValueChanged<Uint8List> onAvatarPicked,
  ) async {
    final picker = ImagePicker();
    final file = await picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 256,
      maxHeight: 256,
      imageQuality: 80,
    );

    if (file != null) {
      final bytes = await file.readAsBytes();
      // Limit to 4KB
      if (bytes.length <= 4096) {
        setState(() => onAvatarPicked(bytes));
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Avatar too large (max 4KB)')),
          );
        }
      }
    }
  }
}

/// Individual chat tile with edit/delete options
class _ChatListTile extends StatelessWidget {
  final ChatMetadata chat;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback onTap;

  const _ChatListTile({
    Key? key,
    required this.chat,
    required this.onEdit,
    required this.onDelete,
    required this.onTap,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: CircleAvatar(
        backgroundImage: chat.avatarBytes != null
            ? MemoryImage(chat.avatarBytes!)
            : null,
        child: chat.avatarBytes == null
            ? const Icon(Icons.chat)
            : null,
      ),
      title: Text(chat.name),
      subtitle: Text(
        'UUID: ${chat.uuid.substring(0, 12)}...',
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.bodySmall,
      ),
      trailing: PopupMenuButton(
        itemBuilder: (context) => [
          PopupMenuItem(
            child: const Text('Edit'),
            onTap: onEdit,
          ),
          PopupMenuItem(
            child: const Text('Delete'),
            onTap: onDelete,
          ),
        ],
      ),
      onTap: onTap,
      onLongPress: onEdit,
    );
  }
}
