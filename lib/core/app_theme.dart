import 'package:flutter/material.dart';

/// Design tokens matching the dark UI spec.
abstract final class AppColors {
  static const bgMain         = Color(0xFF0A0A0C);
  static const bgSurface      = Color(0xFF141417);
  static const bgSurfaceActive = Color(0xFF1F1F24);
  static const textPrimary    = Color(0xFFF5F5F5);
  static const textSecondary  = Color(0xFF8E8E93);
  static const border         = Color(0xFF2C2C30);

  static const statusGreen    = Color(0xFF34C759);
  static const statusOrange   = Color(0xFFFF9F0A);
  static const statusRed      = Color(0xFFFF3B30);
  static const statusGrey     = Color(0xFF636366);

  static const accent         = Color(0xFFFFFFFF);
}

abstract final class AppTheme {
  static ThemeData dark() => ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    scaffoldBackgroundColor: AppColors.bgMain,
    colorScheme: const ColorScheme.dark(
      primary:        AppColors.accent,
      onPrimary:      Colors.black,
      secondary:      AppColors.textSecondary,
      surface:        AppColors.bgSurface,
      onSurface:      AppColors.textPrimary,
      outline:        AppColors.border,
      outlineVariant: AppColors.border,
      error:          AppColors.statusRed,
    ),
    dividerColor: AppColors.border,
    appBarTheme: const AppBarTheme(
      backgroundColor: AppColors.bgMain,
      foregroundColor: AppColors.textPrimary,
      elevation: 0,
      scrolledUnderElevation: 0,
      titleTextStyle: TextStyle(
        fontSize: 22,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.5,
        color: AppColors.textPrimary,
      ),
    ),
    textTheme: const TextTheme(
      bodyLarge:   TextStyle(color: AppColors.textPrimary),
      bodyMedium:  TextStyle(color: AppColors.textPrimary),
      bodySmall:   TextStyle(color: AppColors.textSecondary),
      labelSmall:  TextStyle(color: AppColors.textSecondary),
    ),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: AppColors.bgSurface,
      contentTextStyle: TextStyle(color: AppColors.textPrimary),
    ),
    popupMenuTheme: const PopupMenuThemeData(
      color: AppColors.bgSurface,
      surfaceTintColor: Colors.transparent,
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: AppColors.bgSurface,
    ),
    dialogTheme: const DialogThemeData(
      backgroundColor: AppColors.bgSurface,
    ),
  );
}
