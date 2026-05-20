import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_theme.dart';

/// First-run chat canvas with a warm hero and capability entry points.
class ChatEmptyState extends StatefulWidget {
  final bool ragMode;
  final ValueChanged<String> onPromptTapped;
  final VoidCallback onOpenDocuments;

  const ChatEmptyState({
    super.key,
    required this.ragMode,
    required this.onPromptTapped,
    required this.onOpenDocuments,
  });

  @override
  State<ChatEmptyState> createState() => _ChatEmptyStateState();
}

class _ChatEmptyStateState extends State<ChatEmptyState>
    with SingleTickerProviderStateMixin {
  late final AnimationController _heroController;

  @override
  void initState() {
    super.initState();
    _heroController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 6),
    )..repeat();
  }

  @override
  void dispose() {
    _heroController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final prompts = widget.ragMode
        ? [
            'What is this document about?',
            'List the key points',
            'Summarize for me',
          ]
        : [
            'Explain a concept to me',
            'Help me brainstorm ideas',
            'Summarize a topic',
          ];

    return Material(
      color: Colors.transparent,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxHeight < 620;
          return SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(20, compact ? 24 : 40, 20, 24),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minHeight: constraints.maxHeight - 48,
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _AnimatedLogo(controller: _heroController),
                  SizedBox(height: compact ? 16 : 22),
                  Text(
                    'What shall we explore?',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: colors.textPrimary,
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    widget.ragMode
                        ? 'Bring a document into the conversation.'
                        : 'Start with a question, an idea, or a file.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: colors.textSecondary,
                      fontSize: 13.5,
                      height: 1.4,
                    ),
                  ),
                  SizedBox(height: compact ? 18 : 28),
                  Row(
                    children: [
                      Expanded(
                        child: _FeatureCard(
                          icon: Icons.chat_bubble_outline_rounded,
                          title: 'Chat mode',
                          subtitle: 'Open conversation',
                          color: Theme.of(context).colorScheme.primary,
                          onTap: () => _tapPrompt(prompts[0]),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _FeatureCard(
                          icon: Icons.description_outlined,
                          title: 'Document Q&A',
                          subtitle: 'Ask your files',
                          color: Theme.of(context).colorScheme.secondary,
                          onTap: () {
                            HapticFeedback.selectionClick();
                            widget.onOpenDocuments();
                          },
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    alignment: WrapAlignment.center,
                    children: prompts.map(_promptChip).toList(),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  void _tapPrompt(String label) {
    HapticFeedback.selectionClick();
    widget.onPromptTapped(label);
  }

  Widget _promptChip(String label) {
    final colors = context.colors;
    return InkWell(
      onTap: () => _tapPrompt(label),
      borderRadius: BorderRadius.circular(18),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: colors.surfaceLight.withValues(alpha: 0.78),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: colors.divider),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: colors.textSecondary,
            fontSize: 13,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }
}

class _AnimatedLogo extends StatelessWidget {
  final AnimationController controller;

  const _AnimatedLogo({required this.controller});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final primary = Theme.of(context).colorScheme.primary;

    return SizedBox(
      width: 124,
      height: 124,
      child: AnimatedBuilder(
        animation: controller,
        builder: (context, child) {
          final pulse = 0.5 + (math.sin(controller.value * math.pi * 2) * 0.5);
          return Stack(
            alignment: Alignment.center,
            children: [
              Transform.rotate(
                angle: controller.value * math.pi * 2,
                child: Container(
                  width: 118,
                  height: 118,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: primary.withValues(alpha: 0.16),
                      width: 1.4,
                    ),
                  ),
                ),
              ),
              Container(
                width: 104 + pulse * 6,
                height: 104 + pulse * 6,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: colors.glowPrimary.withValues(alpha: 0.65),
                      blurRadius: 28 + pulse * 10,
                      spreadRadius: 2,
                    ),
                  ],
                ),
              ),
              child!,
            ],
          );
        },
        child: Container(
          width: 88,
          height: 88,
          decoration: BoxDecoration(
            color: colors.surface.withValues(alpha: 0.72),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: colors.divider),
          ),
          clipBehavior: Clip.antiAlias,
          child: Image.asset(
            'assets/logo.png',
            fit: BoxFit.contain,
            errorBuilder: (context, error, stackTrace) =>
                const SizedBox.shrink(),
          ),
        ),
      ),
    );
  }
}

class _FeatureCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final Color color;
  final VoidCallback onTap;

  const _FeatureCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        constraints: const BoxConstraints(minHeight: 106),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: colors.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: color.withValues(alpha: 0.18)),
          boxShadow: [
            BoxShadow(
              color: colors.shadow.withValues(alpha: 0.14),
              blurRadius: 18,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: color, size: 18),
            ),
            const SizedBox(height: 18),
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: colors.textPrimary,
                fontSize: 14,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 3),
            Text(
              subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: colors.textSecondary,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
