import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'package:sgtp_flutter/core/app_notifications/app_notification_models.dart';
import 'package:sgtp_flutter/core/app_notifications/custom_app_notifications_controller.dart';
import 'package:sgtp_flutter/features/notifications/domain/entities/linux_notification_settings.dart';

class CustomAppNotificationsHost extends AnimatedWidget {
  const CustomAppNotificationsHost({super.key, required this.controller})
    : super(listenable: controller);

  final CustomAppNotificationsController controller;

  @override
  Widget build(BuildContext context) {
    final entries = controller.visible;
    if (entries.isEmpty) {
      return const SizedBox.shrink();
    }

    final position = _currentPosition;
    final isTop =
        position == LinuxCustomNotificationPosition.topLeft ||
        position == LinuxCustomNotificationPosition.topRight;
    final mediaSize = MediaQuery.sizeOf(context);
    final maxHeight = math.max(0.0, mediaSize.height - 32);

    return SafeArea(
      child: Align(
        alignment: _alignmentFor(position),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: 392, maxHeight: maxHeight),
            child: SingleChildScrollView(
              reverse: !isTop,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: _crossAxisFor(position),
                children: _buildStackedEntries(entries, position),
              ),
            ),
          ),
        ),
      ),
    );
  }

  LinuxCustomNotificationPosition get _currentPosition {
    final entries = controller.visible;
    if (entries.isNotEmpty) {
      return entries.first.position;
    }
    return controller.settings.position;
  }

  List<Widget> _buildStackedEntries(
    List<CustomAppNotificationEntry> entries,
    LinuxCustomNotificationPosition position,
  ) {
    final ordered = switch (position) {
      LinuxCustomNotificationPosition.bottomLeft ||
      LinuxCustomNotificationPosition.bottomRight => entries.reversed.toList(),
      _ => entries,
    };
    return [
      for (final entry in ordered) ...[
        _NotificationCard(
          entry: entry,
          onClose: () => controller.dismiss(entry.id),
          onTap: entry.onTap == null ? null : () => controller.invokeTap(entry),
          onAction: (index) => controller.invokeAction(entry, index),
        ),
        const SizedBox(height: 11),
      ],
    ];
  }

  Alignment _alignmentFor(LinuxCustomNotificationPosition position) {
    return switch (position) {
      LinuxCustomNotificationPosition.topLeft => Alignment.topLeft,
      LinuxCustomNotificationPosition.topRight => Alignment.topRight,
      LinuxCustomNotificationPosition.bottomLeft => Alignment.bottomLeft,
      LinuxCustomNotificationPosition.bottomRight => Alignment.bottomRight,
    };
  }

  CrossAxisAlignment _crossAxisFor(LinuxCustomNotificationPosition position) {
    return switch (position) {
      LinuxCustomNotificationPosition.topLeft ||
      LinuxCustomNotificationPosition.bottomLeft => CrossAxisAlignment.start,
      _ => CrossAxisAlignment.end,
    };
  }
}

class _NotificationCard extends StatelessWidget {
  const _NotificationCard({
    required this.entry,
    required this.onClose,
    required this.onAction,
    this.onTap,
  });

  final CustomAppNotificationEntry entry;
  final VoidCallback onClose;
  final VoidCallback? onTap;
  final ValueChanged<int> onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final titleStyle =
        theme.textTheme.titleMedium?.copyWith(
          fontSize: 15.5,
          fontWeight: FontWeight.w600,
          color: Colors.white,
        ) ??
        const TextStyle(
          fontSize: 15.5,
          fontWeight: FontWeight.w600,
          color: Colors.white,
        );
    final bodyStyle =
        theme.textTheme.bodyMedium?.copyWith(
          fontSize: 13.5,
          fontWeight: FontWeight.w400,
          color: Colors.white70,
        ) ??
        const TextStyle(
          fontSize: 13.5,
          fontWeight: FontWeight.w400,
          color: Colors.white70,
        );
    final appStyle =
        theme.textTheme.labelLarge?.copyWith(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: Colors.white,
        ) ??
        const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: Colors.white,
        );
    final metaStyle =
        theme.textTheme.bodySmall?.copyWith(
          fontSize: 12,
          fontWeight: FontWeight.w400,
          color: Colors.white54,
        ) ??
        const TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w400,
          color: Colors.white54,
        );

    final content = Container(
      constraints: const BoxConstraints(maxWidth: 392),
      decoration: BoxDecoration(
        color: const Color(0xFF181A20),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white12),
        boxShadow: const [
          BoxShadow(
            color: Color(0x33000000),
            blurRadius: 20,
            offset: Offset(0, 8),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const _AppGlyph(),
                      const SizedBox(width: 7),
                      Text('SGTP', style: appStyle),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        child: Text('·', style: metaStyle),
                      ),
                      Expanded(
                        child: Text(
                          'now',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: metaStyle,
                        ),
                      ),
                      const SizedBox(width: 8),
                      _CloseButton(onPressed: onClose),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _PeerAvatar(
                        avatarBytes: entry.showAvatar
                            ? entry.avatarBytes
                            : null,
                        initials: entry.initials,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              entry.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: titleStyle,
                            ),
                            if ((entry.body ?? '').trim().isNotEmpty) ...[
                              const SizedBox(height: 3),
                              Text(
                                entry.body!,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: bodyStyle,
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            if (entry.actions.isNotEmpty)
              _NotificationActionsBar(
                actions: entry.actions,
                onAction: onAction,
              ),
          ],
        ),
      ),
    );

    final interactive = onTap == null
        ? content
        : Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: onTap,
              child: content,
            ),
          );

    return TweenAnimationBuilder<double>(
      key: ValueKey(entry.id),
      tween: Tween<double>(begin: 0, end: 1),
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      builder: (context, value, child) {
        final slideY =
            entry.position == LinuxCustomNotificationPosition.topLeft ||
                entry.position == LinuxCustomNotificationPosition.topRight
            ? -10.0 * (1 - value)
            : 10.0 * (1 - value);
        return Opacity(
          opacity: value,
          child: Transform.translate(offset: Offset(0, slideY), child: child),
        );
      },
      child: interactive,
    );
  }
}

class _NotificationActionsBar extends StatelessWidget {
  const _NotificationActionsBar({
    required this.actions,
    required this.onAction,
  });

  final List<AppNotificationButton> actions;
  final ValueChanged<int> onAction;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.transparent,
        border: Border(top: BorderSide(color: Colors.white10, width: 0.5)),
      ),
      child: SizedBox(
        height: 44,
        child: Row(
          children: [
            for (var index = 0; index < actions.length; index++) ...[
              Expanded(
                child: _ActionButton(
                  button: actions[index],
                  onPressed: () => onAction(index),
                ),
              ),
              if (index != actions.length - 1)
                VerticalDivider(
                  width: 1,
                  thickness: 0.5,
                  color: Colors.white10,
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class _AppGlyph extends StatelessWidget {
  const _AppGlyph();

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(5),
      child: Image.asset(
        'assets/app_icon.png',
        width: 18,
        height: 18,
        fit: BoxFit.cover,
      ),
    );
  }
}

class _PeerAvatar extends StatelessWidget {
  const _PeerAvatar({required this.avatarBytes, required this.initials});

  final Uint8List? avatarBytes;
  final String initials;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final provider = avatarBytes != null && avatarBytes!.isNotEmpty
        ? MemoryImage(avatarBytes!)
        : null;
    return Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: provider == null ? _gradientForInitials(initials) : null,
        color: provider == null ? null : const Color(0xFF384150),
        border: Border.all(color: Colors.white10, width: 0.5),
        image: provider != null
            ? DecorationImage(image: provider, fit: BoxFit.cover)
            : null,
      ),
      alignment: Alignment.center,
      child: provider == null
          ? Text(
              initials,
              maxLines: 1,
              overflow: TextOverflow.fade,
              style:
                  theme.textTheme.titleSmall?.copyWith(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ) ??
                  const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
            )
          : null,
    );
  }
}

class _CloseButton extends StatelessWidget {
  const _CloseButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 22,
      height: 22,
      child: IconButton(
        onPressed: onPressed,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints.tightFor(width: 22, height: 22),
        style: IconButton.styleFrom(
          backgroundColor: const Color(0xFF23262D),
          shape: const CircleBorder(),
        ),
        icon: const Icon(
          Icons.close_rounded,
          size: 12,
          color: Color(0xFF8C929D),
        ),
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({required this.button, required this.onPressed});

  final AppNotificationButton button;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final isDanger = button.color == AppNotificationButtonColor.red;
    return TextButton(
      onPressed: onPressed,
      style: ButtonStyle(
        minimumSize: WidgetStateProperty.all(const Size.fromHeight(44)),
        padding: WidgetStateProperty.all(
          const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        ),
        foregroundColor: WidgetStateProperty.all(
          isDanger ? Colors.redAccent : Colors.white,
        ),
        overlayColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.hovered)
              ? Colors.white.withValues(alpha: 0.05)
              : null,
        ),
        shape: WidgetStateProperty.all(const RoundedRectangleBorder()),
        textStyle: WidgetStateProperty.all(
          Theme.of(context).textTheme.labelLarge?.copyWith(
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
              ) ??
              const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
        ),
      ),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Text(button.label, maxLines: 1),
      ),
    );
  }
}

LinearGradient _gradientForInitials(String initials) {
  const gradients = <List<Color>>[
    [Color(0xFF5D9CFF), Color(0xFF6B6BFF)],
    [Color(0xFF43B3AE), Color(0xFF5FD17E)],
    [Color(0xFFB06CFF), Color(0xFF6E84FF)],
    [Color(0xFFFF8A5B), Color(0xFFFF5D7A)],
    [Color(0xFF4CB8FF), Color(0xFF3D7BFF)],
  ];
  final normalized = initials.trim().isEmpty ? 'SG' : initials.trim();
  final hash = normalized.codeUnits.fold<int>(0, (sum, unit) => sum + unit);
  final pair = gradients[hash % gradients.length];
  return LinearGradient(
    colors: pair,
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );
}
