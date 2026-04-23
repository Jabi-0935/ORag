import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';

import 'theme/app_theme.dart';
import 'screens/chat_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  // Use bundled fonts only – no network fetching in release mode
  GoogleFonts.config.allowRuntimeFetching = false;

  // Replace Flutter's red error screen with a dark one that matches the app
  ErrorWidget.builder = (FlutterErrorDetails details) {
    return Container(color: const Color(0xFF010212));
  };

  // Lock to portrait for consistent mobile UX
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
  ]);
  // Dark status bar to match splash / theme
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarColor: Color(0xFF010212),
    systemNavigationBarIconBrightness: Brightness.light,
  ));
  runApp(const ProviderScope(child: OragApp()));
}

class OragApp extends StatelessWidget {
  const OragApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'O-RAG',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark,
      home: const ChatScreen(),
    );
  }
}
