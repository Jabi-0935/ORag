import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Custom app colors that Material's ColorScheme does not cover.
class OragColors extends ThemeExtension<OragColors> {
  final Color background;
  final Color surface;
  final Color surfaceLight;
  final Color primaryDim;
  final Color userBubble;
  final Color aiBubble;
  final Color textPrimary;
  final Color textSecondary;
  final Color textDim;
  final Color success;
  final Color warning;
  final Color error;
  final Color divider;
  final Color inputFill;
  final Color inputBorder;
  final Color shimmer;
  final Color glassBackground;
  final Color glowPrimary;
  final Color glowSecondary;
  final Color shadow;

  const OragColors({
    required this.background,
    required this.surface,
    required this.surfaceLight,
    required this.primaryDim,
    required this.userBubble,
    required this.aiBubble,
    required this.textPrimary,
    required this.textSecondary,
    required this.textDim,
    required this.success,
    required this.warning,
    required this.error,
    required this.divider,
    required this.inputFill,
    required this.inputBorder,
    required this.shimmer,
    required this.glassBackground,
    required this.glowPrimary,
    required this.glowSecondary,
    required this.shadow,
  });

  @override
  OragColors copyWith({
    Color? background,
    Color? surface,
    Color? surfaceLight,
    Color? primaryDim,
    Color? userBubble,
    Color? aiBubble,
    Color? textPrimary,
    Color? textSecondary,
    Color? textDim,
    Color? success,
    Color? warning,
    Color? error,
    Color? divider,
    Color? inputFill,
    Color? inputBorder,
    Color? shimmer,
    Color? glassBackground,
    Color? glowPrimary,
    Color? glowSecondary,
    Color? shadow,
  }) {
    return OragColors(
      background: background ?? this.background,
      surface: surface ?? this.surface,
      surfaceLight: surfaceLight ?? this.surfaceLight,
      primaryDim: primaryDim ?? this.primaryDim,
      userBubble: userBubble ?? this.userBubble,
      aiBubble: aiBubble ?? this.aiBubble,
      textPrimary: textPrimary ?? this.textPrimary,
      textSecondary: textSecondary ?? this.textSecondary,
      textDim: textDim ?? this.textDim,
      success: success ?? this.success,
      warning: warning ?? this.warning,
      error: error ?? this.error,
      divider: divider ?? this.divider,
      inputFill: inputFill ?? this.inputFill,
      inputBorder: inputBorder ?? this.inputBorder,
      shimmer: shimmer ?? this.shimmer,
      glassBackground: glassBackground ?? this.glassBackground,
      glowPrimary: glowPrimary ?? this.glowPrimary,
      glowSecondary: glowSecondary ?? this.glowSecondary,
      shadow: shadow ?? this.shadow,
    );
  }

  @override
  OragColors lerp(ThemeExtension<OragColors>? other, double t) {
    if (other is! OragColors) return this;
    return OragColors(
      background: Color.lerp(background, other.background, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      surfaceLight: Color.lerp(surfaceLight, other.surfaceLight, t)!,
      primaryDim: Color.lerp(primaryDim, other.primaryDim, t)!,
      userBubble: Color.lerp(userBubble, other.userBubble, t)!,
      aiBubble: Color.lerp(aiBubble, other.aiBubble, t)!,
      textPrimary: Color.lerp(textPrimary, other.textPrimary, t)!,
      textSecondary: Color.lerp(textSecondary, other.textSecondary, t)!,
      textDim: Color.lerp(textDim, other.textDim, t)!,
      success: Color.lerp(success, other.success, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      error: Color.lerp(error, other.error, t)!,
      divider: Color.lerp(divider, other.divider, t)!,
      inputFill: Color.lerp(inputFill, other.inputFill, t)!,
      inputBorder: Color.lerp(inputBorder, other.inputBorder, t)!,
      shimmer: Color.lerp(shimmer, other.shimmer, t)!,
      glassBackground: Color.lerp(glassBackground, other.glassBackground, t)!,
      glowPrimary: Color.lerp(glowPrimary, other.glowPrimary, t)!,
      glowSecondary: Color.lerp(glowSecondary, other.glowSecondary, t)!,
      shadow: Color.lerp(shadow, other.shadow, t)!,
    );
  }
}

extension OragThemeX on BuildContext {
  OragColors get colors => Theme.of(this).extension<OragColors>()!;
}

class AppTheme {
  AppTheme._();

  // Modern Slate palette (primary blue, secondary teal)
  static const Color _teal = Color(0xFF2563EB); // primary (blue)
  static const Color _tealDark = Color(0xFF60A5FA); // primary (dark variant)
  static const Color _blueAccent = Color(0xFF06B6D4); // secondary (teal)

  static const OragColors lightColors = OragColors(
    background: Color(0xFFF6F8FA),
    surface: Color(0xFFFFFFFF),
    surfaceLight: Color(0xFFF1F5FB),
    primaryDim: Color(0xFF2563EB),
    userBubble: Color(0xFFF1F5F9),
    aiBubble: Color(0xFFFFFFFF),
    textPrimary: Color(0xFF0F172A),
    textSecondary: Color(0xFF475569),
    textDim: Color(0xFF7B8794),
    success: Color(0xFF16A34A),
    warning: Color(0xFFF59E0B),
    error: Color(0xFFEF4444),
    divider: Color(0xFFE6EEF6),
    inputFill: Color(0xFFF8FAFF),
    inputBorder: Color(0xFFDCEAFE),
    shimmer: Color(0xFFEEF7FF),
    glassBackground: Color(0xFFEFF7FF),
    glowPrimary: Color(0x332563EB),
    glowSecondary: Color(0x2606B6D4),
    shadow: Color(0x1F0B1220),
  );

  static const OragColors darkColors = OragColors(
    background: Color(0xFF071428),
    surface: Color(0xFF0B1B2E),
    surfaceLight: Color(0xFF122534),
    primaryDim: Color(0xFF2563EB),
    userBubble: Color(0xFF0F2436),
    aiBubble: Color(0xFF071428),
    textPrimary: Color(0xFFEFF6FF),
    textSecondary: Color(0xFFBBDFFC),
    textDim: Color(0xFF85A6C9),
    success: Color(0xFF34D399),
    warning: Color(0xFFFBBF24),
    error: Color(0xFFFF7A7A),
    divider: Color(0xFF0F2A3E),
    inputFill: Color(0xFF071A28),
    inputBorder: Color(0xFF123248),
    shimmer: Color(0xFF0E2A3E),
    glassBackground: Color(0xDD071428),
    glowPrimary: Color(0x3D60A5FA),
    glowSecondary: Color(0x2606B6D4),
    shadow: Color(0x80000000),
  );

  static ThemeData get light => _build(
    brightness: Brightness.light,
    colors: lightColors,
    primary: _teal,
    secondary: _blueAccent,
  );

  static ThemeData get dark => _build(
    brightness: Brightness.dark,
    colors: darkColors,
    primary: _tealDark,
    secondary: _blueAccent,
  );

  static ThemeData _build({
    required Brightness brightness,
    required OragColors colors,
    required Color primary,
    required Color secondary,
  }) {
    final isDark = brightness == Brightness.dark;
    final base = ThemeData(
      brightness: brightness,
      useMaterial3: true,
      colorScheme: ColorScheme(
        brightness: brightness,
        primary: primary,
        onPrimary: isDark ? const Color(0xFF1A1024) : Colors.white,
        secondary: secondary,
        onSecondary: isDark ? const Color(0xFF1A1024) : Colors.white,
        error: colors.error,
        onError: Colors.white,
        surface: colors.surface,
        onSurface: colors.textPrimary,
      ),
    );
    final textTheme = GoogleFonts.interTextTheme(
      base.textTheme,
    ).apply(bodyColor: colors.textPrimary, displayColor: colors.textPrimary);

    return base.copyWith(
      scaffoldBackgroundColor: colors.background,
      extensions: [colors],
      textTheme: textTheme,
      appBarTheme: AppBarTheme(
        backgroundColor: colors.surface,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: GoogleFonts.inter(
          fontSize: 20,
          fontWeight: FontWeight.w600,
          color: colors.textPrimary,
        ),
        iconTheme: IconThemeData(color: colors.textSecondary),
      ),
      cardTheme: CardThemeData(
        color: colors.surface,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      dividerTheme: DividerThemeData(
        color: colors.divider,
        space: 1,
        thickness: 1,
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: primary,
          foregroundColor: isDark ? const Color(0xFF1A1024) : Colors.white,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: colors.surfaceLight,
        contentTextStyle: GoogleFonts.inter(
          color: colors.textPrimary,
          fontSize: 14,
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        behavior: SnackBarBehavior.floating,
      ),
      iconTheme: IconThemeData(color: colors.textSecondary),
      popupMenuTheme: PopupMenuThemeData(
        color: colors.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: colors.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      ),
    );
  }
}
