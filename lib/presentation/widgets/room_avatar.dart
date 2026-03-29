import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../core/app_theme.dart';

/// Circular avatar used in room tiles and the chat page header.
/// Shows a custom image if [avatarBytes] is set, otherwise a fallback [icon].
class RoomAvatar extends StatelessWidget {
  final Uint8List? avatarBytes;
  final IconData fallbackIcon;
  final double size;

  const RoomAvatar({
    super.key,
    this.avatarBytes,
    this.fallbackIcon = Icons.tag,
    this.size = 48,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: AppColors.bgSurface,
        border: Border.all(color: AppColors.border),
        image: avatarBytes != null
            ? DecorationImage(
                image: MemoryImage(avatarBytes!),
                fit: BoxFit.cover,
              )
            : null,
      ),
      child: avatarBytes == null
          ? Icon(fallbackIcon, size: size * 0.42, color: AppColors.textSecondary)
          : null,
    );
  }
}

/// Bookmark-style avatar for saved (inactive) chat tiles.
class SavedChatAvatar extends StatelessWidget {
  final double size;
  const SavedChatAvatar({super.key, this.size = 48});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: const BoxDecoration(shape: BoxShape.circle),
      child: Icon(Icons.bookmark_outlined,
          size: size * 0.46, color: AppColors.textSecondary),
    );
  }
}
