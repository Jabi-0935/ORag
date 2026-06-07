import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';

import 'controllers/theme_controller.dart';
import 'theme/app_theme.dart';
import 'screens/chat_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  // Use bundled fonts only – no network fetching in release mode
  GoogleFonts.config.allowRuntimeFetching = false;

  // Replace Flutter's red error screen with one that matches the app.
  ErrorWidget.builder = (FlutterErrorDetails details) {
    return Container(color: AppTheme.darkColors.background);
  };

  // Lock to portrait for consistent mobile UX
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  runApp(const ProviderScope(child: OragApp()));
}

class OragApp extends ConsumerWidget {
  const OragApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeControllerProvider);

    return MaterialApp(
      title: 'O-RAG',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: themeMode,
      builder: (context, child) {
        final platformBrightness = MediaQuery.platformBrightnessOf(context);
        final effectiveBrightness = switch (themeMode) {
          ThemeMode.light => Brightness.light,
          ThemeMode.dark => Brightness.dark,
          ThemeMode.system => platformBrightness,
        };
        final colors = Theme.of(context).extension<OragColors>()!;
        final isDark = effectiveBrightness == Brightness.dark;

        return AnnotatedRegion<SystemUiOverlayStyle>(
          value: SystemUiOverlayStyle(
            statusBarColor: Colors.transparent,
            statusBarIconBrightness: isDark
                ? Brightness.light
                : Brightness.dark,
            systemNavigationBarColor: colors.background,
            systemNavigationBarIconBrightness: isDark
                ? Brightness.light
                : Brightness.dark,
          ),
          child: child ?? const SizedBox.shrink(),
        );
      },
      home: const ChatScreen(),
    );
  }
}
