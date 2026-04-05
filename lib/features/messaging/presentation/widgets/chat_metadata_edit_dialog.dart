import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import 'package:sgtp_flutter/core/app_theme.dart';
import 'package:sgtp_flutter/core/widgets/app_bottom_sheet.dart';
import 'package:sgtp_flutter/features/messaging/application/models/messaging_models.dart';

/// Bottom-sheet content panel for editing chat name and avatar.
/// Does NOT wrap itself in any dialog — embed inside [showAppBottomSheet].
class ChatMetadataEditPanel extends StatefulWidget {
  final ChatMetadata chat;
  final void Function(String newName, Uint8List? newAvatar) onSave;
  final VoidCallback onCancel;

  const ChatMetadataEditPanel({
    super.key,
    required this.chat,
    required this.onSave,
    required this.onCancel,
  });

  @override
  State<ChatMetadataEditPanel> createState() => _ChatMetadataEditPanelState();
}

class _ChatMetadataEditPanelState extends State<ChatMetadataEditPanel> {
  late final TextEditingController _nameController;
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
    return Padding(
      padding: EdgeInsets.fromLTRB(
          20, 24, 20, MediaQuery.of(context).viewInsets.bottom + 16),
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
            onTap: _pickAvatar,
            child: CircleAvatar(
              radius: 44,
              backgroundImage: _newAvatarBytes != null
                  ? MemoryImage(_newAvatarBytes!)
                  : null,
              child: _newAvatarBytes == null
                  ? const Icon(Icons.camera_alt, size: 32)
                  : null,
            ),
          ),
          if (_newAvatarBytes != null) ...[
            const SizedBox(height: 4),
            TextButton.icon(
              onPressed: () => setState(() => _newAvatarBytes = null),
              icon: const Icon(Icons.delete_outline, size: 16),
              label: const Text('Remove Avatar'),
            ),
          ],
          const SizedBox(height: 16),
          TextField(
            controller: _nameController,
            style: const TextStyle(color: AppColors.textPrimary),
            decoration: InputDecoration(
              labelText: 'Chat Name',
              hintText: 'Enter new chat name',
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
          const SizedBox(height: 8),
          // UUID info row
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: AppColors.bgSurfaceActive,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppColors.border),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Chat ID',
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textSecondary)),
                const SizedBox(height: 4),
                SelectableText(
                  widget.chat.uuid,
                  style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11,
                      color: AppColors.textPrimary),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _TimeLabel('Created', widget.chat.createdAt),
              _TimeLabel('Updated', widget.chat.updatedAt),
            ],
          ),
          const SizedBox(height: 20),
          Row(children: [
            Expanded(
              child: AppSheetButton(
                label: 'Cancel',
                secondary: true,
                onTap: widget.onCancel,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: AppSheetButton(
                label: 'Save',
                onTap: () {
                  final newName = _nameController.text.trim();
                  if (newName.isEmpty) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                          content: Text('Chat name cannot be empty')),
                    );
                    return;
                  }
                  widget.onSave(newName, _newAvatarBytes);
                },
              ),
            ),
          ]),
        ],
      ),
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
    if (file == null) return;
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

class _TimeLabel extends StatelessWidget {
  final String label;
  final DateTime dt;
  const _TimeLabel(this.label, this.dt);

  @override
  Widget build(BuildContext context) {
    final text =
        '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} '
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: const TextStyle(fontSize: 11, color: AppColors.textSecondary)),
        Text(text,
            style: const TextStyle(fontSize: 11, color: AppColors.textPrimary)),
      ],
    );
  }
}
