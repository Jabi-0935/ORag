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

  static const Color _violet = Color(0xFF7C3AED);
  static const Color _violetDark = Color(0xFF9F7AEA);
  static const Color _rose = Color(0xFFB75C8D);

  static const OragColors lightColors = OragColors(
    background: Color(0xFFFFFAF7),
    surface: Color(0xFFFFFFFF),
    surfaceLight: Color(0xFFF6F0FA),
    primaryDim: Color(0xFF6D28D9),
    userBubble: Color(0xFFF0E7FF),
    aiBubble: Color(0xFFFFFAF7),
    textPrimary: Color(0xFF241B2F),
    textSecondary: Color(0xFF665C73),
    textDim: Color(0xFF94899F),
    success: Color(0xFF2F8A62),
    warning: Color(0xFFC7831C),
    error: Color(0xFFD34A4A),
    divider: Color(0xFFE8DFF0),
    inputFill: Color(0xEFFFFFFF),
    inputBorder: Color(0xFFE0D4EA),
    shimmer: Color(0xFFEDE4F4),
    glassBackground: Color(0xDDFDF8F5),
    glowPrimary: Color(0x337C3AED),
    glowSecondary: Color(0x26B75C8D),
    shadow: Color(0x1F3A253F),
  );

  static const OragColors darkColors = OragColors(
    background: Color(0xFF15101C),
    surface: Color(0xFF1F1728),
    surfaceLight: Color(0xFF2A2034),
    primaryDim: Color(0xFF7C3AED),
    userBubble: Color(0xFF342745),
    aiBubble: Color(0xFF15101C),
    textPrimary: Color(0xFFF8F3FA),
    textSecondary: Color(0xFFC8BCD3),
    textDim: Color(0xFF8F829E),
    success: Color(0xFF70D6A6),
    warning: Color(0xFFF2B85B),
    error: Color(0xFFFF7A7A),
    divider: Color(0xFF3A2D47),
    inputFill: Color(0xD9231A2D),
    inputBorder: Color(0xFF493859),
    shimmer: Color(0xFF3B2E48),
    glassBackground: Color(0xDD1B1423),
    glowPrimary: Color(0x3D9F7AEA),
    glowSecondary: Color(0x2EB75C8D),
    shadow: Color(0x80000000),
  );

  static ThemeData get light => _build(
    brightness: Brightness.light,
    colors: lightColors,
    primary: _violet,
    secondary: _rose,
  );

  static ThemeData get dark => _build(
    brightness: Brightness.dark,
    colors: darkColors,
    primary: _violetDark,
    secondary: const Color(0xFFD18AB2),
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
