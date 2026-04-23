import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../services/platform_service.dart';
import '../theme/app_theme.dart';

/// Full-screen overlay shown during model download + load.
/// Single AnimationController drives a rotating arc around the logo.
/// All animations are GPU-composited (RotationTransition, FadeTransition).
class InitOverlay extends StatefulWidget {
  final InitStatus status;
  final VoidCallback? onRetry;

  const InitOverlay({
    super.key,
    required this.status,
    this.onRetry,
  });

  @override
  State<InitOverlay> createState() => _InitOverlayState();
}

class _InitOverlayState extends State<InitOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _spinController;

  @override
  void initState() {
    super.initState();
    _spinController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    )..repeat();
  }

  @override
  void dispose() {
    _spinController.dispose();
    super.dispose();
  }

  bool get _isActive =>
      widget.status.state == InitState.idle ||
      widget.status.state == InitState.downloading ||
      widget.status.state == InitState.loading;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF040123),
      child: SafeArea(
        child: Column(
          children: [
            // Push content to upper-center (about 35% from top)
            const Spacer(flex: 3),

            // Logo section
            _buildLogoSection(),
            const SizedBox(height: 20),

            // App name
            Text(
              'O-RAG',
              style: GoogleFonts.inter(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: Colors.white,
                letterSpacing: 3,
              ),
            ),

            const SizedBox(height: 32),

            // Status text — single line, no redundant title
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 48),
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 300),
                child: Text(
                  _statusText,
                  key: ValueKey(_statusText),
                  style: GoogleFonts.inter(
                    color: AppColors.textPrimary,
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
            ),

            const SizedBox(height: 6),

            // Hint text (secondary info)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 48),
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 300),
                child: Text(
                  _hintText,
                  key: ValueKey(_hintText),
                  style: GoogleFonts.inter(
                    color: AppColors.textDim,
                    fontSize: 12,
                  ),
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),

            const SizedBox(height: 32),

            // Progress bar
            if (widget.status.state == InitState.downloading ||
                widget.status.state == InitState.loading)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 64),
                child: _buildProgressBar(),
              ),

            // Error retry
            if (widget.status.isError) ...[
              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (widget.onRetry != null) ...[
                    OutlinedButton.icon(
                      onPressed: widget.onRetry,
                      icon: const Icon(Icons.refresh_rounded, size: 16),
                      label: const Text('Retry'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.primary,
                        side: BorderSide(
                          color: AppColors.primary.withValues(alpha: 0.3),
                        ),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 24, vertical: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                    ),
                ],
              ),
            ],

            const Spacer(flex: 4),
          ],
        ),
      ),
    );
  }

  Widget _buildLogoSection() {
    final isError = widget.status.state == InitState.error;
    final isReady = widget.status.state == InitState.ready;

    if (isError) {
      return _buildStatusIcon(Icons.error_outline_rounded, AppColors.error);
    }
    if (isReady) {
      return _buildStatusIcon(
          Icons.check_circle_outline_rounded, AppColors.success);
    }

    // Logo + rotating arc ring
    return SizedBox(
      width: 110,
      height: 110,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Rotating arc — GPU composited via RotationTransition
          if (_isActive)
            RotationTransition(
              turns: _spinController,
              child: CustomPaint(
                size: const Size(110, 110),
                painter: _ArcPainter(
                  color: AppColors.primary,
                  strokeWidth: 1.5,
                ),
              ),
            ),
          // Logo
          ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: Image.asset(
              'assets/logo.png',
              width: 76,
              height: 76,
              errorBuilder: (_, __, ___) => const SizedBox(
                width: 76,
                height: 76,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusIcon(IconData icon, Color color) {
    return Container(
      width: 80,
      height: 80,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color.withValues(alpha: 0.08),
      ),
      child: Icon(icon, size: 38, color: color),
    );
  }



  Widget _buildProgressBar() {
    final progress = widget.status.progress;
    return Column(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(2),
          child: SizedBox(
            height: 3,
            child: LinearProgressIndicator(
              value: progress > 0.01 ? progress : null,
              backgroundColor: Colors.white.withValues(alpha: 0.06),
              valueColor:
                  const AlwaysStoppedAnimation<Color>(AppColors.primary),
            ),
          ),
        ),
        if (progress > 0.01) ...[
          const SizedBox(height: 8),
          Text(
            '${(progress * 100).toInt()}%',
            style: GoogleFonts.inter(
              color: AppColors.textDim,
              fontSize: 11,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ],
    );
  }

  /// Primary status text — uses the backend message when available,
  /// otherwise shows a clean default. Avoids redundant "Loading" + "Loading…"
  String get _statusText {
    final msg = widget.status.message;

    switch (widget.status.state) {
      case InitState.idle:
        return 'Preparing AI engine…';
      case InitState.downloading:
        // Use the backend message directly (e.g. "Downloading Chat Model… 45%")
        return msg.isNotEmpty ? msg : 'Downloading…';
      case InitState.loading:
        // Use the backend message but prevent "Loading" title + "Loading…" message
        if (msg.isNotEmpty) return msg;
        return 'Starting AI engine…';
      case InitState.ready:
        return 'Ready to chat!';
      case InitState.error:
        return msg.isNotEmpty ? msg : 'Could not initialize the AI engine.';
    }
  }

  /// Secondary hint text shown below the status
  String get _hintText {
    switch (widget.status.state) {
      case InitState.idle:
        return 'This may take a moment';
      case InitState.downloading:
        return 'First launch only · stay on Network! ';
      case InitState.loading:
        return 'Almost there…';
      case InitState.ready:
        return '';
      case InitState.error:
        return 'Please check your connection and try again';
    }
  }
}

/// Draws a partial arc — painted once, then rotated by GPU via RotationTransition.
class _ArcPainter extends CustomPainter {
  final Color color;
  final double strokeWidth;

  _ArcPainter({required this.color, required this.strokeWidth});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color.withValues(alpha: 0.5)
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;

    final rect = Rect.fromLTWH(
      strokeWidth / 2,
      strokeWidth / 2,
      size.width - strokeWidth,
      size.height - strokeWidth,
    );

    // Main arc — 100°
    canvas.drawArc(rect, 0, math.pi * 0.56, false, paint);

    // Opposite dimmer arc — 60°
    final dimPaint = Paint()
      ..color = color.withValues(alpha: 0.15)
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(rect, math.pi, math.pi * 0.33, false, dimPaint);
  }

  @override
  bool shouldRepaint(covariant _ArcPainter old) =>
      color != old.color || strokeWidth != old.strokeWidth;
}
