import 'package:flutter/material.dart';

import '../../core/app_theme.dart';
import '../blocs/chat/chat_state.dart';

/// Small coloured circle indicating a single room's connection status.
class RoomStatusDot extends StatelessWidget {
  final ChatStatus status;
  final double size;

  const RoomStatusDot({super.key, required this.status, this.size = 6});

  Color get _color => switch (status) {
    ChatStatus.ready        => AppColors.statusGreen,
    ChatStatus.connecting   => AppColors.statusOrange,
    ChatStatus.handshaking  => AppColors.statusOrange,
    ChatStatus.error        => AppColors.statusRed,
    ChatStatus.disconnected => AppColors.statusGrey,
  };

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: _color, shape: BoxShape.circle),
    );
  }
}

/// Larger status dot for the AppBar — shows aggregate status across all rooms,
/// with a glow when at least one room is ready.
class GlobalStatusDot extends StatelessWidget {
  final List<ChatStatus> statuses;

  const GlobalStatusDot({super.key, required this.statuses});

  (Color, Color?) get _colorAndGlow {
    if (statuses.any((s) => s == ChatStatus.ready)) {
      return (AppColors.statusGreen, AppColors.statusGreen);
    }
    if (statuses.any(
        (s) => s == ChatStatus.connecting || s == ChatStatus.handshaking)) {
      return (AppColors.statusOrange, null);
    }
    if (statuses.isNotEmpty) return (AppColors.statusRed, null);
    return (AppColors.statusGrey, null);
  }

  @override
  Widget build(BuildContext context) {
    final (color, glowColor) = _colorAndGlow;
    return Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        boxShadow: glowColor != null
            ? [BoxShadow(color: glowColor.withAlpha(100), blurRadius: 10)]
            : null,
      ),
    );
  }
}
