import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_theme.dart';

/// Empty state with logo, subtitle, and tappable example prompt chips.
class ChatEmptyState extends StatelessWidget {
  final bool ragMode;
  final ValueChanged<String> onPromptTapped;

  const ChatEmptyState({
    super.key,
    required this.ragMode,
    required this.onPromptTapped,
  });

  @override
  Widget build(BuildContext context) {
    final prompts = ragMode
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

    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Logo
          Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              color: Colors.transparent,
            ),
            clipBehavior: Clip.antiAlias,
            child: Image.asset(
              'assets/logo.png',
              width: 80,
              height: 80,
              fit: BoxFit.contain,
              errorBuilder: (_, __, ___) =>
                  const SizedBox(width: 80, height: 80),
            ),
          ),
          const SizedBox(height: 20),
          const Text(
            'How can I assist you?',
            style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: 18,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            ragMode
                ? 'Ask anything about your document'
                : 'Start a conversation',
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 24),
          // Tappable example prompt chips
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: prompts.map((l) => _promptChip(l)).toList(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _promptChip(String label) {
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        onPromptTapped(label);
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: AppColors.surfaceLight,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: AppColors.divider),
        ),
        child: Text(
          label,
          style: const TextStyle(
            color: AppColors.textSecondary,
            fontSize: 13,
          ),
        ),
      ),
    );
  }
}
