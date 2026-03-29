import 'dart:ui';

import 'package:flutter/material.dart';

import '../../core/app_theme.dart';

/// Bottom navigation bar with a frosted-glass dark background.
/// Place on a [Scaffold] with [extendBody: true] so the blur filter has
/// content to render through.
class AppNavBar extends StatelessWidget {
  final int selectedIndex;
  final ValueChanged<int> onTap;

  const AppNavBar({
    super.key,
    required this.selectedIndex,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final bottomPad = MediaQuery.of(context).padding.bottom;
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: Container(
          decoration: const BoxDecoration(
            color: Color(0xD90A0A0C), // ~85 % opacity
            border: Border(top: BorderSide(color: AppColors.border)),
          ),
          padding: EdgeInsets.only(bottom: bottomPad),
          child: Row(
            children: [
              _NavItem(
                icon: Icons.forum_outlined,
                activeIcon: Icons.forum,
                label: 'Rooms',
                isActive: selectedIndex == 0,
                onTap: () => onTap(0),
              ),
              _NavItem(
                icon: Icons.settings_outlined,
                activeIcon: Icons.settings,
                label: 'Settings',
                isActive: selectedIndex == 1,
                onTap: () => onTap(1),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  final IconData icon;
  final IconData activeIcon;
  final String label;
  final bool isActive;
  final VoidCallback onTap;

  const _NavItem({
    required this.icon,
    required this.activeIcon,
    required this.label,
    required this.isActive,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = isActive ? AppColors.accent : AppColors.textSecondary;
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(isActive ? activeIcon : icon, size: 26, color: color),
              const SizedBox(height: 4),
              Text(
                label,
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w500,
                  color: color,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
