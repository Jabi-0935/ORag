import 'package:flutter/material.dart';

import '../models/chat_message.dart';
import '../theme/app_theme.dart';
import 'chat_bubble.dart';
import 'chat_empty_state.dart';
import 'typing_indicator.dart';

/// The scrollable message list including empty state, system messages,
/// chat bubbles, and the typing indicator.
class ChatMessageList extends StatelessWidget {
  final List<ChatMessage> messages;
  final bool initDone;
  final bool ragMode;
  final ScrollController scrollController;
  final ValueChanged<String> onPromptTapped;
  final VoidCallback onOpenDocuments;

  const ChatMessageList({
    super.key,
    required this.messages,
    required this.initDone,
    required this.ragMode,
    required this.scrollController,
    required this.onPromptTapped,
    required this.onOpenDocuments,
  });

  @override
  Widget build(BuildContext context) {
    if (messages.isEmpty && initDone) {
      return ChatEmptyState(
        ragMode: ragMode,
        onPromptTapped: onPromptTapped,
        onOpenDocuments: onOpenDocuments,
      );
    }

    return ListView.builder(
      controller: scrollController,
      padding: const EdgeInsets.symmetric(vertical: 12),
      itemCount: messages.length,
      itemBuilder: (context, index) {
        final msg = messages[index];

        // System messages render as centered info cards
        if (msg.role == MessageRole.system) {
          return _buildSystemMessage(context, msg);
        }

        // If this is the AI message and it's streaming but empty, show typing indicator
        if (msg.isAssistant && msg.isStreaming && msg.isEmpty) {
          return const TypingIndicator();
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Slide + fade entrance animation
            TweenAnimationBuilder<double>(
              tween: Tween(begin: 0.0, end: 1.0),
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOut,
              builder: (ctx, val, child) => Opacity(
                opacity: val,
                child: Transform.translate(
                  offset: Offset(0, 12 * (1 - val)),
                  child: child,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [ChatBubble(message: msg)],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildSystemMessage(BuildContext context, ChatMessage msg) {
    final colors = context.colors;
    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 32, vertical: 8),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: colors.surfaceLight.withValues(alpha: 0.75),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: colors.divider, width: 1),
        ),
        child: Text(
          msg.text,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: colors.textSecondary,
            fontSize: 13,
            height: 1.4,
          ),
        ),
      ),
    );
  }
}
