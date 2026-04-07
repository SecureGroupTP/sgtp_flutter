import 'dart:typed_data';

import 'package:flutter/material.dart';

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

  static const _gradients = [
    [Color(0xFFFF7676), Color(0xFFE53935)],
    [Color(0xFFFFAE34), Color(0xFFF57C00)],
    [Color(0xFF66CC6C), Color(0xFF2E7D32)],
    [Color(0xFF4DD0E1), Color(0xFF0097A7)],
    [Color(0xFF42A5F5), Color(0xFF1E88E5)],
    [Color(0xFF7E57C2), Color(0xFF4527A0)],
    [Color(0xFFAB47BC), Color(0xFF7B1FA2)],
    [Color(0xFFEC407A), Color(0xFFC2185B)],
  ];

  static List<Color> gradientForName(String name) {
    int h = 0;
    for (int i = 0; i < name.length; i++) {
      h = name.codeUnitAt(i) + ((h << 5) - h);
    }
    return _gradients[h.abs() % _gradients.length];
  }

  bool get _hasAvatarBytes => avatarBytes != null && avatarBytes!.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final name = fallbackName.trim();
    final initial = name.isNotEmpty ? name[0].toUpperCase() : '?';
    final gradient = gradientForName(name);
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
