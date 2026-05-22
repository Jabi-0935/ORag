import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_theme.dart';

/// Minimal chat empty state: logo-only hero, primary action card, two prompts,
/// and a compact left-aligned "Browse documents" button.
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
            'Explain Physics to me',
            'Summarize what is physics',
          ];
    final primaryPrompt = prompts.first;

    return Material(
      color: Colors.transparent,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxHeight < 640;
          return SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(20, compact ? 20 : 36, 20, 24),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minHeight: constraints.maxHeight - 48,
              ),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 540),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _HeroPanel(
                        controller: _heroController,
                        ragMode: widget.ragMode,
                      ),
                      SizedBox(height: compact ? 16 : 22),
                      SizedBox(height: compact ? 18 : 24),
                      _ActionCard(
                        key: const ValueKey('empty_state_primary_action'),
                        title: widget.ragMode
                            ? 'Open document Q&A'
                            : 'Try the first prompt',
                        subtitle: widget.ragMode
                            ? 'Bring a file into the conversation'
                            : 'Jump straight into a conversation starter',
                        icon: widget.ragMode
                            ? Icons.description_outlined
                            : Icons.auto_awesome_rounded,
                        color: Theme.of(context).colorScheme.primary,
                        onTap: widget.ragMode
                            ? () {
                                HapticFeedback.selectionClick();
                                widget.onOpenDocuments();
                              }
                            : () => _tapPrompt(primaryPrompt),
                      ),
                      const SizedBox(height: 16),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          'Quick prompts',
                          style: TextStyle(
                            color: colors.textDim,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 0.3,
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        alignment: WrapAlignment.center,
                        children: prompts.map(_promptChip).toList(),
                      ),
                      const SizedBox(height: 8),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          key: const ValueKey('empty_state_documents_action'),
                          style: TextButton.styleFrom(
                            padding: EdgeInsets.zero,
                            minimumSize: const Size(0, 0),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          onPressed: () {
                            HapticFeedback.selectionClick();
                            widget.onOpenDocuments();
                          },
                          icon: const Icon(Icons.folder_open_outlined, size: 18),
                          label: const Text('Browse documents'),
                        ),
                      ),
                    ],
                  ),
                ),
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
      key: ValueKey('empty_state_prompt_chip_$label'),
      onTap: () => _tapPrompt(label),
      borderRadius: BorderRadius.circular(999),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        decoration: BoxDecoration(
          color: colors.surfaceLight.withValues(alpha: 0.92),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: colors.divider.withValues(alpha: 0.9)),
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

class _HeroPanel extends StatelessWidget {
  final AnimationController controller;
  final bool ragMode;

  const _HeroPanel({required this.controller, required this.ragMode});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return AnimatedBuilder(
      animation: controller,
      builder: (context, child) {
        final pulse = 0.5 + (math.sin(controller.value * math.pi * 2) * 0.5);

        return Padding(
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 10),
          child: Column(
            children: [
              Stack(
                alignment: Alignment.center,
                children: [
                  Container(
                    width: 150,
                    height: 150,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: RadialGradient(
                        colors: [
                          scheme.primary.withValues(alpha: 0.14),
                          scheme.primary.withValues(alpha: 0.04),
                          Colors.transparent,
                        ],
                        stops: const [0.0, 0.62, 1.0],
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 110 + pulse * 4,
                    height: 110 + pulse * 4,
                    child: Image.asset(
                      'assets/logo.png',
                      fit: BoxFit.contain,
                      errorBuilder: (context, error, stackTrace) => const SizedBox.shrink(),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
            ],
          ),
        );
      },
    );
  }
}

class _ActionCard extends StatelessWidget {
  const _ActionCard({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.color,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: colors.surface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: color.withValues(alpha: 0.14)),
          boxShadow: [
            BoxShadow(
              color: colors.shadow.withValues(alpha: 0.08),
              blurRadius: 16,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(icon, color: color, size: 20),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: colors.textPrimary,
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        subtitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: colors.textSecondary,
                          fontSize: 12.5,
                          height: 1.3,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Icon(
                  Icons.arrow_forward_rounded,
                  color: colors.textDim,
                  size: 18,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

