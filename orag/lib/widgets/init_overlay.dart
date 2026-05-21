import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../services/platform_service.dart';
import '../theme/app_theme.dart';

/// Full-screen overlay shown during model download + load.
class InitOverlay extends StatelessWidget {
  final InitStatus status;
  final VoidCallback? onRetry;

  const InitOverlay({super.key, required this.status, this.onRetry});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final scheme = Theme.of(context).colorScheme;

    return Stack(
      children: [
        Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                colors.background,
                colors.surfaceLight.withValues(alpha: 0.54),
                colors.background,
              ],
            ),
          ),
        ),
        SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      _buildLogoSection(colors, scheme),
                      const SizedBox(height: 12),
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 220),
                        child: Text(
                          _statusText,
                          key: ValueKey(_statusText),
                          textAlign: TextAlign.center,
                          style: GoogleFonts.inter(
                            color: colors.textPrimary,
                            fontSize: 18,
                            height: 1.15,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 220),
                        child: Text(
                          _hintText,
                          key: ValueKey(
                            '${status.state}-${_hintText.isEmpty ? 'empty' : 'hint'}',
                          ),
                          textAlign: TextAlign.center,
                          style: GoogleFonts.inter(
                            color: colors.textDim,
                            fontSize: 13,
                            height: 1.45,
                          ),
                        ),
                      ),
                      if (status.state == InitState.downloading ||
                          status.state == InitState.loading) ...[
                        const SizedBox(height: 12),
                        _buildProgressCard(colors, scheme),
                      ],
                      if (status.isError) ...[
                        const SizedBox(height: 12),
                        OutlinedButton.icon(
                          onPressed: onRetry,
                          icon: const Icon(Icons.refresh_rounded, size: 16),
                          label: const Text('Retry initialization'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: scheme.primary,
                            side: BorderSide(
                              color: scheme.primary.withValues(alpha: 0.24),
                            ),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 18,
                              vertical: 12,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildLogoSection(OragColors colors, ColorScheme scheme) {
    switch (status.state) {
      case InitState.error:
        return _buildStatusIcon(colors.error, Icons.error_outline_rounded);
      case InitState.ready:
        return _buildStatusIcon(colors.success, Icons.check_circle_outline_rounded);
      case InitState.idle:
      case InitState.downloading:
      case InitState.loading:
        return SizedBox(
          width: 116,
          height: 116,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Container(
                width: 78,
                height: 78,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      scheme.primary.withValues(alpha: 0.08),
                      scheme.primary.withValues(alpha: 0.02),
                      Colors.transparent,
                    ],
                    stops: const [0.0, 0.68, 1.0],
                  ),
                ),
              ),
              Container(
                width: 84,
                height: 84,
                decoration: BoxDecoration(
                  color: colors.surface.withValues(alpha: 0.82),
                  borderRadius: BorderRadius.circular(22),
                  border: Border.all(
                    color: colors.divider.withValues(alpha: 0.85),
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: colors.shadow.withValues(alpha: 0.06),
                      blurRadius: 12,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                clipBehavior: Clip.antiAlias,
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Image.asset(
                    'assets/logo.png',
                    fit: BoxFit.contain,
                    errorBuilder: (context, error, stackTrace) =>
                        const SizedBox.shrink(),
                  ),
                ),
              ),
            ],
          ),
        );
    }
  }

  Widget _buildStatusIcon(Color color, IconData icon) {
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

  Widget _buildProgressCard(OragColors colors, ColorScheme scheme) {
    final progress = status.progress;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 8,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: progress > 0.01 ? progress : null,
              backgroundColor: colors.surfaceLight.withValues(alpha: 0.6),
              valueColor: AlwaysStoppedAnimation<Color>(scheme.primary),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'Progress',
              style: GoogleFonts.inter(
                color: colors.textDim,
                fontSize: 11,
                fontWeight: FontWeight.w500,
              ),
            ),
            Text(
              '${(progress * 100).toInt()}%',
              style: GoogleFonts.inter(
                color: colors.textPrimary,
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ],
    );
  }

  String _sanitizeMsg(String message) {
    return message
        .replaceAll(RegExp(r'\[.*?\]\s*'), '')
        .replaceAll(RegExp(r'\(.*?s\)\s*'), '')
        .trim();
  }

  String get _statusText {
    final msg = _sanitizeMsg(status.message);

    switch (status.state) {
      case InitState.idle:
        return 'Booting the AI engine';
      case InitState.loading:
        return msg.isNotEmpty ? msg : 'Loading the local model';
      case InitState.downloading:
        return msg.isNotEmpty ? msg : 'Preparing the model files';
      case InitState.ready:
        return 'Ready to chat';
      case InitState.error:
        return msg.isNotEmpty ? msg : 'Could not initialize the AI engine.';
    }
  }

  String get _hintText {
    switch (status.state) {
      case InitState.idle:
        return 'Starting up the local engine.';
      case InitState.downloading:
        return 'First launch only · keep the app open while assets download.';
      case InitState.loading:
        return 'Loading the model and warming up the session.';
      case InitState.ready:
        return 'Ready to chat.';
      case InitState.error:
        return 'Please check your connection and try again';
    }
  }
}
