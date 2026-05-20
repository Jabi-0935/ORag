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

  const InitOverlay({super.key, required this.status, this.onRetry});

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
    final colors = context.colors;

    return Container(
      color: colors.background,
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
                color: colors.textPrimary,
                letterSpacing: 2,
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
                    color: colors.textPrimary,
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
                  style: GoogleFonts.inter(color: colors.textDim, fontSize: 12),
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
                        foregroundColor: Theme.of(context).colorScheme.primary,
                        side: BorderSide(
                          color: Theme.of(
                            context,
                          ).colorScheme.primary.withValues(alpha: 0.3),
                        ),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 24,
                          vertical: 12,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                    ),
                  ],
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
    final colors = context.colors;
    final scheme = Theme.of(context).colorScheme;
    final isError = widget.status.state == InitState.error;
    final isReady = widget.status.state == InitState.ready;

    if (isError) {
      return _buildStatusIcon(Icons.error_outline_rounded, colors.error);
    }
    if (isReady) {
      return _buildStatusIcon(
        Icons.check_circle_outline_rounded,
        colors.success,
      );
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
                painter: _ArcPainter(color: scheme.primary, strokeWidth: 1.5),
              ),
            ),
          // Logo
          Container(
            width: 76,
            height: 76,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              color: Colors.transparent,
            ),
            clipBehavior: Clip.antiAlias,
            child: Image.asset(
              'assets/logo.png',
              width: 76,
              height: 76,
              fit: BoxFit.contain,
              errorBuilder: (context, error, stackTrace) =>
                  const SizedBox(width: 76, height: 76),
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
    final colors = context.colors;
    final scheme = Theme.of(context).colorScheme;
    final progress = widget.status.progress;
    return Column(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: SizedBox(
            height: 6,
            child: LinearProgressIndicator(
              value: progress > 0.01 ? progress : null,
              backgroundColor: colors.surfaceLight.withValues(alpha: 0.48),
              valueColor: AlwaysStoppedAnimation<Color>(scheme.primary),
            ),
          ),
        ),
        if (progress > 0.01) ...[
          const SizedBox(height: 8),
          Text(
            '${(progress * 100).toInt()}%',
            style: GoogleFonts.inter(
              color: colors.textDim,
              fontSize: 11,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ],
    );
  }

  /// Cleans up developer brackets from backend messages (e.g., "[LOAD]", "[BOOTSTRAP]", "(12.3s)")
  String _sanitizeMsg(String message) {
    return message
        .replaceAll(RegExp(r'\[.*?\]\s*'), '')
        .replaceAll(RegExp(r'\(.*?s\)\s*'), '')
        .trim();
  }

  String get _statusText {
    final msg = _sanitizeMsg(widget.status.message);

    switch (widget.status.state) {
      case InitState.idle:
        return 'Preparing the AI engine…';
      case InitState.loading:
        return msg.isNotEmpty ? msg : 'Preparing the AI engine…';
      case InitState.downloading:
        return msg.isNotEmpty ? msg : 'Downloading…';
      case InitState.ready:
        return 'Ready to chat!';
      case InitState.error:
        final errorMsg = _sanitizeMsg(widget.status.message);
        return errorMsg.isNotEmpty
            ? errorMsg
            : 'Could not initialize the AI engine.';
    }
  }

  /// Secondary hint text shown below the status
  String get _hintText {
    switch (widget.status.state) {
      case InitState.idle:
      case InitState.loading:
      case InitState.ready:
        return '';
      case InitState.downloading:
        return 'First launch only · stay on Network! ';
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
