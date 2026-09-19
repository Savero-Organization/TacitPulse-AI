import 'package:flutter/material.dart';

import 'app_colors.dart';

/// Tema Industrial Dark Mode: kontras tinggi, ramah area pabrik/lapangan.
abstract final class AppTheme {
  static ThemeData get dark {
    const scheme = ColorScheme.dark(
      primary: AppColors.industrialAmber,
      onPrimary: AppColors.slateDark,
      secondary: AppColors.cyanAccent,
      onSecondary: AppColors.slateDark,
      surface: AppColors.deepCharcoal,
      onSurface: AppColors.textPrimary,
      error: AppColors.danger,
      onError: Colors.white,
      outline: AppColors.surfaceBorder,
      outlineVariant: AppColors.slateMuted,
    );

    final base = ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: scheme,
      scaffoldBackgroundColor: AppColors.slateDark,
      fontFamily: 'Roboto',
    );

    return base.copyWith(
      appBarTheme: const AppBarTheme(
        backgroundColor: AppColors.deepCharcoal,
        foregroundColor: AppColors.textPrimary,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: AppColors.textPrimary,
          fontSize: 18,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.2,
        ),
      ),
      cardTheme: CardThemeData(
        color: AppColors.deepCharcoal,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: const BorderSide(color: AppColors.surfaceBorder, width: 1),
        ),
      ),
      dividerTheme: const DividerThemeData(
        color: AppColors.surfaceBorder,
        thickness: 1,
        space: 1,
      ),
      chipTheme: ChipThemeData(
        backgroundColor: AppColors.slateMuted,
        side: const BorderSide(color: AppColors.surfaceBorder),
        labelStyle: const TextStyle(color: AppColors.textPrimary, fontSize: 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        padding: const EdgeInsets.symmetric(horizontal: 8),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColors.slateDark,
        hintStyle: const TextStyle(color: AppColors.textMuted),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.surfaceBorder),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.surfaceBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.cyanAccent, width: 1.5),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: AppColors.deepCharcoal,
        indicatorColor: const Color(0xFFB45309),
        labelTextStyle: WidgetStatePropertyAll(
          const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        ),
      ),
      textTheme: base.textTheme.apply(
        bodyColor: AppColors.textPrimary,
        displayColor: AppColors.textPrimary,
      ),
    );
  }
}