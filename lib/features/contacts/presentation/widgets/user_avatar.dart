import 'dart:typed_data';
import 'package:flutter/material.dart';

/// Circular avatar that shows [bytes] if provided, otherwise falls back to
/// a deterministic gradient derived from [name] with the first letter as
/// an initial. The gradient palette matches the contacts screen design.
class UserAvatar extends StatelessWidget {
  final Uint8List? bytes;
  final String name;
  final double size;
  final Border? border;

  const UserAvatar({
    super.key,
    required this.name,
    this.bytes,
    this.size = 46,
    this.border,
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

  bool get _hasAvatarBytes => bytes != null && bytes!.isNotEmpty;

  @override
  Widget build(BuildContext context) {
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
        border: border,
      ),
      child: _hasAvatarBytes
          ? ClipOval(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  placeholder,
                  Image.memory(
                    bytes!,
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
