import 'package:flutter/material.dart';

/// Design tokens matching the dark UI spec (chat-v2.html).
abstract final class AppColors {
  static const bgMain          = Color(0xFF0A0A0C);
  static const bgSurface       = Color(0xFF141417);
  static const bgSurfaceActive = Color(0xFF1F1F24);
  static const textPrimary     = Color(0xFFF5F5F5);
  static const textSecondary   = Color(0xFF8E8E93);
  static const border          = Color(0xFF2C2C30);

  static const accentBlue      = Color(0xFF0A84FF);
  static const accentBlueDark  = Color(0xFF0056B3);

  static const statusGreen     = Color(0xFF34C759);
  static const statusOrange    = Color(0xFFFF9F0A);
  static const statusRed       = Color(0xFFFF3B30);
  static const statusGrey      = Color(0xFF636366);

  // accent = WHITE (nav active, FABs) — as per HTML --accent: #ffffff
  // accentBlue used only for chat-specific elements (send button, own bubbles)
  static const accent          = Color(0xFFFFFFFF);
}

abstract final class AppTheme {
  static ThemeData dark() => ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    scaffoldBackgroundColor: AppColors.bgMain,

    colorScheme: const ColorScheme.dark(
      primary:                 AppColors.accentBlue,
      onPrimary:               Colors.white,
      primaryContainer:        AppColors.accentBlue,
      onPrimaryContainer:      Colors.white,
      secondary:               AppColors.textSecondary,
      secondaryContainer:      AppColors.bgSurfaceActive,
      onSecondaryContainer:    AppColors.textPrimary,
      surface:                 AppColors.bgSurface,
      onSurface:               AppColors.textPrimary,
      surfaceContainerHighest: AppColors.bgSurfaceActive,
      onSurfaceVariant:        AppColors.textSecondary,
      outline:                 AppColors.border,
      outlineVariant:          AppColors.border,
      error:                   AppColors.statusRed,
      onError:                 Colors.white,
      shadow:                  Colors.black,
    ),

    dividerColor: AppColors.border,

    appBarTheme: const AppBarTheme(
      backgroundColor:        AppColors.bgMain,
      foregroundColor:        AppColors.textPrimary,
      elevation:              0,
      scrolledUnderElevation: 0,
      titleTextStyle: TextStyle(
        fontSize:      16,
        fontWeight:    FontWeight.w600,
        letterSpacing: -0.3,
        color:         AppColors.textPrimary,
      ),
    ),

    textTheme: const TextTheme(
      bodyLarge:   TextStyle(color: AppColors.textPrimary),
      bodyMedium:  TextStyle(color: AppColors.textPrimary, fontSize: 15),
      bodySmall:   TextStyle(color: AppColors.textSecondary, fontSize: 12),
      labelSmall:  TextStyle(color: AppColors.textSecondary, fontSize: 11),
      titleMedium: TextStyle(
          color: AppColors.textPrimary,
          fontSize: 16,
          fontWeight: FontWeight.w600),
    ),

    inputDecorationTheme: InputDecorationTheme(
      hintStyle: const TextStyle(color: AppColors.textSecondary),
      filled:    true,
      fillColor: AppColors.bgSurfaceActive,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(20),
        borderSide: const BorderSide(color: AppColors.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(20),
        borderSide: const BorderSide(color: AppColors.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(20),
        borderSide: const BorderSide(color: AppColors.border),
      ),
      disabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(20),
        borderSide: const BorderSide(color: AppColors.border),
      ),
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
    ),

    snackBarTheme: const SnackBarThemeData(
      backgroundColor:  AppColors.bgSurface,
      contentTextStyle: TextStyle(color: AppColors.textPrimary),
    ),

    popupMenuTheme: const PopupMenuThemeData(
      color:            AppColors.bgSurface,
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
