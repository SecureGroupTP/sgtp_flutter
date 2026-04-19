import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:sgtp_flutter/core/avatar/avatar_fallback.dart';

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

  bool get _hasAvatarBytes => bytes != null && bytes!.isNotEmpty;

  @override
  Widget build(BuildContext context) {
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
