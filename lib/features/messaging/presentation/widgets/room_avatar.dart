import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'package:sgtp_flutter/core/avatar/avatar_fallback.dart';
import 'package:sgtp_flutter/core/app_theme.dart';

/// Circular avatar used in room tiles and the chat page header.
/// Shows a custom image if [avatarBytes] is set, otherwise a deterministic
/// gradient derived from [fallbackName] with the first letter as an initial.
class RoomAvatar extends StatelessWidget {
  final Uint8List? avatarBytes;
  final IconData fallbackIcon;
  final String fallbackName;
  final double size;

  const RoomAvatar({
    super.key,
    this.avatarBytes,
    this.fallbackIcon = Icons.tag,
    this.fallbackName = 'Chat',
    this.size = 48,
  });

  bool get _hasAvatarBytes => avatarBytes != null && avatarBytes!.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final name = AvatarFallback.normalizeName(fallbackName);
    final initial = AvatarFallback.initialForName(name);
    final gradient = AvatarFallback.gradientForName(name);
    final fontSize = (size * 0.38).clamp(11.0, 22.0);
    final placeholder = Center(
      child: Text(
        initial,
        style: TextStyle(
          fontSize: fontSize,
          fontWeight: FontWeight.bold,
          color: Colors.white,
        ),
      ),
    );

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: gradient,
        ),
        border: Border.all(color: AppColors.border),
      ),
      child: _hasAvatarBytes
          ? ClipOval(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  placeholder,
                  Image.memory(
                    avatarBytes!,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                  ),
                ],
              ),
            )
          : placeholder,
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
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: AppColors.border),
      ),
      child: Icon(Icons.bookmark_outlined,
          size: size * 0.46, color: AppColors.textSecondary),
    );
  }
}
