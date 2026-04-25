import 'package:flutter/material.dart';

import 'package:sgtp_flutter/core/app_theme.dart';

/// Unified bottom sheet launcher.
/// Standardises background colour, corner radius (24), and scroll control.
Future<T?> showAppBottomSheet<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  bool isScrollControlled = true,
}) {
  return showModalBottomSheet<T>(
    context: context,
    backgroundColor: AppColors.bgSurface,
    isScrollControlled: isScrollControlled,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: builder,
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// AppSheetButton
// ─────────────────────────────────────────────────────────────────────────────

/// Full-width action button for use inside bottom sheets.
///
/// Variants:
///   default   — accent fill (primary action)
///   secondary — muted fill with border
///   danger    — red fill (destructive action)
class AppSheetButton extends StatelessWidget {
  final String label;
  final VoidCallback? onTap;
  final IconData? icon;
  final bool secondary;
  final bool danger;

  const AppSheetButton({
    super.key,
    required this.label,
    required this.onTap,
    this.icon,
    this.secondary = false,
    this.danger = false,
  });

  @override
  Widget build(BuildContext context) {
    final Color bg;
    final Color fg;
    if (danger) {
      bg = AppColors.statusRed;
      fg = Colors.white;
    } else if (secondary) {
      bg = AppColors.bgSurfaceActive;
      fg = AppColors.textPrimary;
    } else {
      bg = AppColors.accent;
      fg = Colors.black;
    }

    return Opacity(
      opacity: onTap == null ? 0.4 : 1.0,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: double.infinity,
          height: 48,
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(12),
            border: secondary ? Border.all(color: AppColors.border) : null,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 18, color: fg),
                const SizedBox(width: 8),
              ],
              Text(
                label,
                style: TextStyle(
                    fontSize: 15, fontWeight: FontWeight.w600, color: fg),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// showAppConfirmSheet
// ─────────────────────────────────────────────────────────────────────────────

/// Standard confirmation bottom sheet — title + body text + cancel / confirm.
/// Returns [true] if the user pressed confirm, [false] otherwise.
Future<bool> showAppConfirmSheet(
  BuildContext context, {
  required String title,
  required String body,
  required String confirmLabel,
  String cancelLabel = 'Cancel',
  bool danger = false,
}) async {
  final result = await showAppBottomSheet<bool>(
    context,
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: AppColors.textPrimary,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              body,
              style: const TextStyle(
                fontSize: 14,
                color: AppColors.textSecondary,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 24),
            Row(children: [
              Expanded(
                child: AppSheetButton(
                  label: cancelLabel,
                  secondary: true,
                  onTap: () => Navigator.pop(ctx, false),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: AppSheetButton(
                  label: confirmLabel,
                  danger: danger,
                  onTap: () => Navigator.pop(ctx, true),
                ),
              ),
            ]),
          ],
        ),
      ),
    ),
  );
  return result == true;
}

// ─────────────────────────────────────────────────────────────────────────────
// AppSheetTile
// ─────────────────────────────────────────────────────────────────────────────

/// List-tile row for picker-style bottom sheets.
/// Pops [sheetContext] with [value] when tapped.
class AppSheetTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String? subtitle;
  final String value;
  final BuildContext sheetContext;

  const AppSheetTile({
    super.key,
    required this.icon,
    required this.label,
    this.subtitle,
    required this.value,
    required this.sheetContext,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => Navigator.pop(sheetContext, value),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        child: Row(children: [
          Icon(icon, color: AppColors.textSecondary, size: 22),
          const SizedBox(width: 16),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(label,
                  style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 16,
                      fontWeight: FontWeight.w400)),
              if (subtitle != null)
                Text(subtitle!,
                    style: const TextStyle(
                        color: AppColors.textSecondary, fontSize: 12)),
            ],
          ),
        ]),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// AppSheetOrDivider
// ─────────────────────────────────────────────────────────────────────────────

/// Horizontal "or" divider for separating action groups in bottom sheets.
class AppSheetOrDivider extends StatelessWidget {
  const AppSheetOrDivider({super.key});

  @override
  Widget build(BuildContext context) {
    return const Row(children: [
      Expanded(child: Divider(color: AppColors.border)),
      Padding(
        padding: EdgeInsets.symmetric(horizontal: 12),
        child: Text('or',
            style: TextStyle(fontSize: 13, color: AppColors.textSecondary)),
      ),
      Expanded(child: Divider(color: AppColors.border)),
    ]);
  }
}
