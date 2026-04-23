import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:intl/intl.dart';
import '../models/chat_message.dart';
import '../theme/app_theme.dart';

/// A styled chat bubble for user or AI messages.
/// AI messages render markdown (bold, code, lists, headings).
/// AI messages include a speaker button for text-to-speech.
class ChatBubble extends StatefulWidget {
  final ChatMessage message;

  const ChatBubble({super.key, required this.message});

  @override
  State<ChatBubble> createState() => _ChatBubbleState();
}

class _ChatBubbleState extends State<ChatBubble> {
  static final FlutterTts _tts = FlutterTts();
  // Track which message is currently speaking to prevent race conditions
  static int? _currentlySpeakingHash;
  bool _isSpeaking = false;

  @override
  void initState() {
    super.initState();
    _tts.setCompletionHandler(() {
      if (mounted) setState(() => _isSpeaking = false);
    });
  }

  @override
  void dispose() {
    if (_isSpeaking) _tts.stop();
    super.dispose();
  }

  Future<void> _toggleTts() async {
    if (_isSpeaking) {
      await _tts.stop();
      _currentlySpeakingHash = null;
      setState(() => _isSpeaking = false);
    } else {
      // Stop any currently speaking bubble first
      if (_currentlySpeakingHash != null) {
        await _tts.stop();
      }
      _currentlySpeakingHash = widget.message.hashCode;
      await _tts.setLanguage('en-US');
      await _tts.setSpeechRate(0.45);
      await _tts.speak(widget.message.text);
      setState(() => _isSpeaking = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isUser = widget.message.isUser;

    return Padding(
      padding: EdgeInsets.only(
        left: isUser ? 48 : 12,
        right: isUser ? 12 : 48,
        top: 4,
        bottom: 4,
      ),
      child: Row(
        mainAxisAlignment:
            isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!isUser) _avatar(isUser),
          if (!isUser) const SizedBox(width: 8),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _bubble(isUser),
                // Timestamp
                Padding(
                  padding: const EdgeInsets.only(top: 3, left: 4, right: 4),
                  child: Text(
                    DateFormat.jm().format(widget.message.timestamp),
                    style: const TextStyle(
                      color: AppColors.textDim,
                      fontSize: 10,
                    ),
                  ),
                ),
                // TTS speaker button for assistant messages
                if (!isUser && widget.message.text.isNotEmpty && !widget.message.isStreaming)
                  Padding(
                    padding: const EdgeInsets.only(top: 2, left: 4),
                    child: GestureDetector(
                      onTap: _toggleTts,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            _isSpeaking ? Icons.stop_circle_rounded : Icons.volume_up_rounded,
                            size: 16,
                            color: _isSpeaking
                                ? AppColors.error
                                : AppColors.textDim.withValues(alpha: 0.6),
                          ),
                          const SizedBox(width: 4),
                          Text(
                            _isSpeaking ? 'Stop' : 'Listen',
                            style: TextStyle(
                              fontSize: 11,
                              color: _isSpeaking
                                  ? AppColors.error
                                  : AppColors.textDim.withValues(alpha: 0.6),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (isUser) const SizedBox(width: 8),
          if (isUser) _avatar(isUser),
        ],
      ),
    );
  }

  Widget _avatar(bool isUser) {
    return Container(
      width: 32,
      height: 32,
      margin: const EdgeInsets.only(top: 2),
      decoration: BoxDecoration(
        color: isUser
            ? AppColors.primary.withValues(alpha: 0.15)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        border: !isUser
            ? Border.all(
                color: AppColors.secondary.withValues(alpha: 0.3),
                width: 1,
              )
            : null,
      ),
      child: isUser
          ? const Icon(
              Icons.person_rounded,
              size: 18,
              color: AppColors.primary,
            )
          : ClipRRect(
              borderRadius: BorderRadius.circular(11),
              child: Image.asset(
                'assets/logo.png',
                fit: BoxFit.cover,
              ),
            ),
    );
  }

  Widget _bubble(bool isUser) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: isUser ? AppColors.userBubble : AppColors.aiBubble,
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(18),
          topRight: const Radius.circular(18),
          bottomLeft: Radius.circular(isUser ? 18 : 4),
          bottomRight: Radius.circular(isUser ? 4 : 18),
        ),
        border: Border.all(
          color: isUser
              ? AppColors.primary.withValues(alpha: 0.08)
              : AppColors.divider,
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.15),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: isUser ? _userText() : _aiMarkdown(),
    );
  }

  /// Plain text for user messages.
  Widget _userText() {
    return SelectableText(
      widget.message.text,
      style: const TextStyle(
        color: AppColors.textPrimary,
        fontSize: 14.5,
        height: 1.5,
      ),
    );
  }

  /// Markdown-rendered text for AI messages.
  Widget _aiMarkdown() {
    final text =
        widget.message.text.isEmpty && widget.message.isStreaming ? ' ' : widget.message.text;

    return MarkdownBody(
      data: text,
      selectable: true,
      styleSheet: MarkdownStyleSheet(
        // Body text
        p: const TextStyle(
          color: AppColors.textPrimary,
          fontSize: 14.5,
          height: 1.6,
        ),
        // Bold
        strong: const TextStyle(
          color: AppColors.textPrimary,
          fontWeight: FontWeight.w700,
        ),
        // Italic
        em: const TextStyle(
          color: AppColors.textPrimary,
          fontStyle: FontStyle.italic,
        ),
        // Inline code + code block text (same property)
        code: TextStyle(
          color: AppColors.primary,
          backgroundColor: AppColors.surfaceLight.withValues(alpha: 0.6),
          fontSize: 13,
          fontFamily: 'monospace',
        ),
        // Code block container
        codeblockDecoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppColors.divider, width: 1),
        ),
        codeblockPadding: const EdgeInsets.all(12),
        // Headings
        h1: const TextStyle(
          color: AppColors.textPrimary,
          fontSize: 20,
          fontWeight: FontWeight.w700,
          height: 1.4,
        ),
        h2: const TextStyle(
          color: AppColors.textPrimary,
          fontSize: 18,
          fontWeight: FontWeight.w600,
          height: 1.4,
        ),
        h3: const TextStyle(
          color: AppColors.textPrimary,
          fontSize: 16,
          fontWeight: FontWeight.w600,
          height: 1.4,
        ),
        // List bullets
        listBullet: const TextStyle(
          color: AppColors.primary,
          fontSize: 14.5,
        ),
        // Blockquote
        blockquote: const TextStyle(
          color: AppColors.textSecondary,
          fontSize: 14,
          fontStyle: FontStyle.italic,
        ),
        blockquoteDecoration: BoxDecoration(
          border: Border(
            left: BorderSide(
              color: AppColors.secondary.withValues(alpha: 0.4),
              width: 3,
            ),
          ),
        ),
        blockquotePadding: const EdgeInsets.only(left: 12, top: 4, bottom: 4),
        // Horizontal rule
        horizontalRuleDecoration: BoxDecoration(
          border: Border(
            top: BorderSide(
              color: AppColors.divider,
              width: 1,
            ),
          ),
        ),
        // Table
        tableHead: const TextStyle(
          color: AppColors.textPrimary,
          fontWeight: FontWeight.w600,
          fontSize: 13,
        ),
        tableBody: const TextStyle(
          color: AppColors.textSecondary,
          fontSize: 13,
        ),
        tableBorder: TableBorder.all(
          color: AppColors.divider,
          width: 1,
        ),
        // Links
        a: const TextStyle(
          color: AppColors.primary,
          decoration: TextDecoration.underline,
        ),
      ),
    );
  }
}
