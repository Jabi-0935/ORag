import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'chat_screen.dart';

/// Animated splash screen that shows the O-RAG logo with a fade-in + scale
/// animation, a subtle pulsing glow, and a loading indicator before
/// transitioning to the main ChatScreen.
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with TickerProviderStateMixin {
  // Background color from the brand
  static const Color _bgColor = Color(0xFF040123);

  late final AnimationController _fadeController;
  late final Animation<double> _fadeAnim;
  late final Animation<double> _scaleAnim;

  late final AnimationController _pulseController;
  late final Animation<double> _pulseAnim;

  late final AnimationController _textFadeController;
  late final Animation<double> _textFadeAnim;

  @override
  void initState() {
    super.initState();

    // ── Logo fade-in & scale ──────────────────────────────────────────
    _fadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );
    _fadeAnim = CurvedAnimation(
      parent: _fadeController,
      curve: Curves.easeOut,
    );
    _scaleAnim = Tween<double>(begin: 0.7, end: 1.0).animate(
      CurvedAnimation(parent: _fadeController, curve: Curves.easeOutBack),
    );

    // ── Subtle pulse glow ─────────────────────────────────────────────
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat(reverse: true);
    _pulseAnim = Tween<double>(begin: 0.3, end: 0.7).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    // ── App name text fade ────────────────────────────────────────────
    _textFadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    _textFadeAnim = CurvedAnimation(
      parent: _textFadeController,
      curve: Curves.easeIn,
    );

    // Kick off the animation sequence
    _fadeController.forward();

    // Show app name after logo is mostly visible
    Future.delayed(const Duration(milliseconds: 800), () {
      if (mounted) _textFadeController.forward();
    });

    // Navigate to ChatScreen after splash
    Future.delayed(const Duration(milliseconds: 3000), _navigateToHome);
  }

  void _navigateToHome() {
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 600),
        pageBuilder: (_, __, ___) => const ChatScreen(),
        transitionsBuilder: (_, animation, __, child) {
          return FadeTransition(opacity: animation, child: child);
        },
      ),
    );
  }

  @override
  void dispose() {
    _fadeController.dispose();
    _pulseController.dispose();
    _textFadeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bgColor,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // ── Animated logo ─────────────────────────────────────────
            AnimatedBuilder(
              animation: Listenable.merge([
                _fadeController,
                _pulseController,
              ]),
              builder: (context, child) {
                return Opacity(
                  opacity: _fadeAnim.value,
                  child: Transform.scale(
                    scale: _scaleAnim.value,
                    child: Container(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: const Color(0xFF00D4AA)
                                .withValues(alpha: _pulseAnim.value * 0.25),
                            blurRadius: 60,
                            spreadRadius: 20,
                          ),
                        ],
                      ),
                      child: child,
                    ),
                  ),
                );
              },
              child: Image.asset(
                'assets/logo.png',
                width: 160,
                height: 160,
              ),
            ),

            const SizedBox(height: 32),

            // ── App name ──────────────────────────────────────────────
            FadeTransition(
              opacity: _textFadeAnim,
              child: Text(
                'O-RAG',
                style: GoogleFonts.inter(
                  fontSize: 28,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                  letterSpacing: 6,
                ),
              ),
            ),

            const SizedBox(height: 8),

            FadeTransition(
              opacity: _textFadeAnim,
              child: Text(
                'Offline Retrieval-Augmented Generation',
                style: GoogleFonts.inter(
                  fontSize: 12,
                  fontWeight: FontWeight.w400,
                  color: Colors.white.withValues(alpha: 0.5),
                  letterSpacing: 1.5,
                ),
              ),
            ),

            const SizedBox(height: 48),

            // ── Loading indicator ─────────────────────────────────────
            FadeTransition(
              opacity: _fadeAnim,
              child: const SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  valueColor: AlwaysStoppedAnimation<Color>(
                    Color(0xFF00D4AA),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
