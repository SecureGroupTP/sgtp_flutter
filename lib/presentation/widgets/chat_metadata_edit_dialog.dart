import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../domain/entities/chat_metadata.dart';

class ChatMetadataEditDialog extends StatefulWidget {
  final ChatMetadata chat;
  final Function(String newName, Uint8List? newAvatar) onSave;

  const ChatMetadataEditDialog({
    Key? key,
    required this.chat,
    required this.onSave,
  }) : super(key: key);

  @override
  State<ChatMetadataEditDialog> createState() => _ChatMetadataEditDialogState();
}

class _ChatMetadataEditDialogState extends State<ChatMetadataEditDialog> {
  late TextEditingController _nameController;
  late Uint8List? _newAvatarBytes;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.chat.name);
    _newAvatarBytes = widget.chat.avatarBytes;
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Edit Chat'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // Avatar
            GestureDetector(
              onTap: _pickAvatar,
              child: CircleAvatar(
                radius: 50,
                backgroundImage: _newAvatarBytes != null
                    ? MemoryImage(_newAvatarBytes!)
                    : null,
                child: _newAvatarBytes == null
                    ? const Icon(Icons.camera_alt, size: 32)
                    : null,
              ),
            ),
            const SizedBox(height: 12),
            if (_newAvatarBytes != null)
              TextButton.icon(
                onPressed: () {
                  setState(() => _newAvatarBytes = null);
                },
                icon: const Icon(Icons.delete, size: 16),
                label: const Text('Remove Avatar'),
              ),
            const SizedBox(height: 20),

            // Chat name field
            TextField(
              controller: _nameController,
              decoration: const InputDecoration(
                labelText: 'Chat Name',
                hintText: 'Enter new chat name',
                border: OutlineInputBorder(),
              ),
              maxLength: 100,
            ),
            const SizedBox(height: 12),

            // UUID info (read-only)
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.grey[200],
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Chat ID',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: Colors.grey,
                    ),
                  ),
                  const SizedBox(height: 4),
                  SelectableText(
                    widget.chat.uuid,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),

            // Timestamps
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Created',
                      style: TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                    Text(
                      _formatTime(widget.chat.createdAt),
                      style: const TextStyle(fontSize: 11),
                    ),
                  ],
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Updated',
                      style: TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                    Text(
                      _formatTime(widget.chat.updatedAt),
                      style: const TextStyle(fontSize: 11),
                    ),
                  ],
                ),
              ],
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
            final newName = _nameController.text.trim();
            if (newName.isEmpty) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Chat name cannot be empty')),
              );
              return;
            }
            widget.onSave(newName, _newAvatarBytes);
          },
          child: const Text('Save'),
        ),
      ],
    );
  }

  Future<void> _pickAvatar() async {
    final picker = ImagePicker();
    final file = await picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 256,
      maxHeight: 256,
      imageQuality: 80,
    );

    if (file != null) {
      final bytes = await file.readAsBytes();
      if (bytes.length <= 4096) {
        setState(() => _newAvatarBytes = bytes);
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Avatar too large (max 4KB)')),
          );
        }
      }
    }
  }

  String _formatTime(DateTime dt) {
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} '
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }
}
