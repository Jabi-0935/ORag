import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// O-RAG Design System
/// Premium dark theme with deep navy backgrounds and cyan-teal accents.

class AppColors {
  AppColors._();

  // Core backgrounds
  static const Color background = Color(0xFF010212);
  static const Color surface = Color(0xFF07081A);
  static const Color surfaceLight = Color(0xFF0E1126);

  // Accents
  static const Color primary = Color(0xFF00D4AA);
  static const Color primaryDim = Color(0xFF00A888);
  static const Color secondary = Color(0xFF6C63FF);

  // Chat bubbles
  static const Color userBubble = Color(0xFF1A2744);
  static const Color aiBubble = Color(0xFF0F1B2E);

  // Text
  static const Color textPrimary = Color(0xFFF0F0F5);
  static const Color textSecondary = Color(0xFF8B8FAE);
  static const Color textDim = Color(0xFF5A5E78);

  // Status
  static const Color error = Color(0xFFFF6B6B);
  static const Color success = Color(0xFF00D4AA);
  static const Color warning = Color(0xFFFFB946);

  // Misc
  static const Color divider = Color(0xFF1E2345);
  static const Color inputFill = Color(0xFF111628);
  static const Color inputBorder = Color(0xFF252A45);
  static const Color shimmer = Color(0xFF2A3055);

  // Glassmorphism & glow
  static const Color glassBackground = Color(0xCC07081A); // ~80% opacity
  static const Color glowPrimary = Color(0x3300D4AA);     // ~20% opacity
  static const Color glowSecondary = Color(0x336C63FF);    // ~20% opacity
}

class AppTheme {
  AppTheme._();

  static ThemeData get dark {
    final base = ThemeData.dark();
    final textTheme = GoogleFonts.interTextTheme(base.textTheme).apply(
      bodyColor: AppColors.textPrimary,
      displayColor: AppColors.textPrimary,
    );

    return base.copyWith(
      scaffoldBackgroundColor: AppColors.background,
      colorScheme: const ColorScheme.dark(
        primary: AppColors.primary,
        secondary: AppColors.secondary,
        surface: AppColors.surface,
        error: AppColors.error,
        onPrimary: AppColors.background,
        onSecondary: AppColors.textPrimary,
        onSurface: AppColors.textPrimary,
        onError: AppColors.textPrimary,
      ),
      textTheme: textTheme,
      appBarTheme: AppBarTheme(
        backgroundColor: AppColors.surface,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: GoogleFonts.inter(
          fontSize: 20,
          fontWeight: FontWeight.w600,
          color: AppColors.textPrimary,
        ),
        iconTheme: const IconThemeData(color: AppColors.textSecondary),
      ),
      cardTheme: CardThemeData(
        color: AppColors.surface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: AppColors.surfaceLight,
        contentTextStyle: GoogleFonts.inter(
          color: AppColors.textPrimary,
          fontSize: 14,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
        behavior: SnackBarBehavior.floating,
      ),
      iconTheme: const IconThemeData(
        color: AppColors.textSecondary,
      ),
    );
  }
}
