import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_tts/flutter_tts.dart';
import '../models/chat_message.dart';
import '../theme/app_theme.dart';
import 'thinking_dropdown.dart';

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
    return isUser ? _buildUserMessage() : _buildAiMessage();
  }

  // ── User message: right-aligned colored bubble with avatar ────────────

  Widget _buildUserMessage() {
    final colors = context.colors;
    final scheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.only(left: 48, right: 12, top: 4, bottom: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Flexible(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: colors.userBubble,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(18),
                  topRight: Radius.circular(18),
                  bottomLeft: Radius.circular(18),
                  bottomRight: Radius.circular(4),
                ),
                border: Border.all(
                  color: scheme.primary.withValues(alpha: 0.10),
                  width: 1,
                ),
                boxShadow: [
                  BoxShadow(
                    color: colors.shadow.withValues(alpha: 0.14),
                    blurRadius: 12,
                    offset: const Offset(0, 5),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  SelectableText(
                    widget.message.text,
                    style: TextStyle(
                      color: colors.textPrimary,
                      fontSize: 14.5,
                      height: 1.5,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          _avatar(true),
        ],
      ),
    );
  }

  // ── AI message: no bubble, text on chat background with avatar ────────

  Widget _buildAiMessage() {
    final colors = context.colors;
    final hasActions =
        widget.message.text.isNotEmpty && !widget.message.isStreaming;

    return Padding(
      padding: const EdgeInsets.only(left: 12, right: 48, top: 4, bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Column(
            children: [
              _avatar(false),
              if (widget.message.responseStyle != null) ...[
                const SizedBox(height: 8),
                Tooltip(
                  message: widget.message.responseStyle == 'concise'
                      ? 'Concise Mode'
                      : 'Detailed Mode',
                  child: Icon(
                    widget.message.responseStyle == 'concise'
                        ? Icons.bolt_rounded
                        : Icons.auto_awesome_rounded,
                    size: 16,
                    color: widget.message.responseStyle == 'concise'
                        ? colors.warning
                        : Theme.of(context).colorScheme.secondary,
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(width: 10),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // AI markdown content — directly on chat background
                _aiMarkdown(),

                // Action bar: icon-only buttons
                if (hasActions)
                  Padding(
                    padding: const EdgeInsets.only(top: 6, left: 0),
                    child: Row(
                      children: [
                        _actionIcon(
                          icon: _isSpeaking
                              ? Icons.stop_circle_rounded
                              : Icons.volume_up_rounded,
                          tooltip: _isSpeaking ? 'Stop' : 'Listen',
                          color: _isSpeaking
                              ? colors.error
                              : colors.textDim.withValues(alpha: 0.62),
                          onTap: _toggleTts,
                        ),
                        const SizedBox(width: 10),
                        _actionIcon(
                          icon: Icons.copy_rounded,
                          tooltip: 'Copy',
                          color: colors.textDim.withValues(alpha: 0.62),
                          onTap: () {
                            Clipboard.setData(
                              ClipboardData(text: widget.message.text),
                            );
                            HapticFeedback.lightImpact();
                          },
                        ),
                        if (widget.message.hasThinking) ...[
                          const SizedBox(width: 10),
                          _actionIcon(
                            icon: Icons.lightbulb_outline,
                            tooltip: 'Thinking',
                            color: colors.textDim.withValues(alpha: 0.62),
                            onTap: _showThinkingModal,
                          ),
                        ],
                        if (widget.message.hasSources ||
                            widget.message.hasParentChunks) ...[
                          const SizedBox(width: 10),
                          _actionIcon(
                            icon: Icons.source_rounded,
                            tooltip: 'Sources',
                            color: colors.textDim.withValues(alpha: 0.62),
                            onTap: _showMergedSourcesModal,
                          ),
                        ],
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── Shared helpers ────────────────────────────────────────────────────

  Widget _actionIcon({
    required IconData icon,
    required String tooltip,
    required Color color,
    required VoidCallback onTap,
  }) {
    final colors = context.colors;

    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: () {
          HapticFeedback.lightImpact();
          onTap();
        },
        child: Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            color: colors.surfaceLight.withValues(alpha: 0.58),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(icon, size: 15, color: color),
        ),
      ),
    );
  }

  Widget _avatar(bool isUser) {
    final scheme = Theme.of(context).colorScheme;

    return Container(
      width: 32,
      height: 32,
      margin: const EdgeInsets.only(top: 2),
      decoration: BoxDecoration(
        color: isUser
            ? scheme.primary.withValues(alpha: 0.13)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        border: !isUser
            ? Border.all(
                color: scheme.secondary.withValues(alpha: 0.30),
                width: 1,
              )
            : null,
      ),
      child: isUser
          ? Icon(Icons.person_rounded, size: 18, color: scheme.primary)
          : ClipRRect(
              borderRadius: BorderRadius.circular(11),
              child: Image.asset('assets/logo.png', fit: BoxFit.cover),
            ),
    );
  }

  /// Markdown-rendered text for AI messages.
  Widget _aiMarkdown() {
    final colors = context.colors;
    final scheme = Theme.of(context).colorScheme;
    final text = widget.message.text.isEmpty && widget.message.isStreaming
        ? ' '
        : widget.message.text;

    return MarkdownBody(
      data: text,
      selectable: true,
      styleSheet: MarkdownStyleSheet(
        // Body text
        p: TextStyle(color: colors.textPrimary, fontSize: 14.5, height: 1.6),
        // Bold
        strong: TextStyle(
          color: colors.textPrimary,
          fontWeight: FontWeight.w700,
        ),
        // Italic
        em: TextStyle(color: colors.textPrimary, fontStyle: FontStyle.italic),
        // Inline code + code block text (same property)
        code: TextStyle(
          color: scheme.primary,
          backgroundColor: colors.surfaceLight.withValues(alpha: 0.72),
          fontSize: 13,
          fontFamily: 'monospace',
        ),
        // Code block container
        codeblockDecoration: BoxDecoration(
          color: colors.surface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: colors.divider, width: 1),
        ),
        codeblockPadding: const EdgeInsets.all(12),
        // Headings
        h1: TextStyle(
          color: colors.textPrimary,
          fontSize: 20,
          fontWeight: FontWeight.w700,
          height: 1.4,
        ),
        h2: TextStyle(
          color: colors.textPrimary,
          fontSize: 18,
          fontWeight: FontWeight.w600,
          height: 1.4,
        ),
        h3: TextStyle(
          color: colors.textPrimary,
          fontSize: 16,
          fontWeight: FontWeight.w600,
          height: 1.4,
        ),
        // List bullets
        listBullet: TextStyle(color: scheme.primary, fontSize: 14.5),
        // Blockquote
        blockquote: TextStyle(
          color: colors.textSecondary,
          fontSize: 14,
          fontStyle: FontStyle.italic,
        ),
        blockquoteDecoration: BoxDecoration(
          border: Border(
            left: BorderSide(
              color: scheme.secondary.withValues(alpha: 0.4),
              width: 3,
            ),
          ),
        ),
        blockquotePadding: const EdgeInsets.only(left: 12, top: 4, bottom: 4),
        // Horizontal rule
        horizontalRuleDecoration: BoxDecoration(
          border: Border(top: BorderSide(color: colors.divider, width: 1)),
        ),
        // Table
        tableHead: TextStyle(
          color: colors.textPrimary,
          fontWeight: FontWeight.w600,
          fontSize: 13,
        ),
        tableBody: TextStyle(color: colors.textSecondary, fontSize: 13),
        tableBorder: TableBorder.all(color: colors.divider, width: 1),
        // Links
        a: TextStyle(
          color: scheme.primary,
          decoration: TextDecoration.underline,
        ),
      ),
    );
  }

  void _showThinkingModal() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => _buildModalContainer(
        title: 'Model Thinking',
        icon: Icons.lightbulb_outline,
        child: ThinkingDropdown(
          thinkingText: widget.message.thinkingText,
          initiallyExpanded: true,
        ),
      ),
    );
  }

  /// Merged Sources modal: lists documents, each expandable to show context chunks.
  void _showMergedSourcesModal() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => _buildModalContainer(
        title: 'Sources',
        icon: Icons.source_rounded,
        child: _MergedSourcesContent(
          sources: widget.message.sources,
          parentChunks: widget.message.parentChunks,
        ),
      ),
    );
  }

  Widget _buildModalContainer({
    required String title,
    required IconData icon,
    required Widget child,
  }) {
    final colors = context.colors;
    final scheme = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.only(top: 12),
      decoration: BoxDecoration(
        color: colors.background,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.8,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: colors.divider,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Icon(icon, size: 20, color: scheme.primary),
                const SizedBox(width: 8),
                Text(
                  title,
                  style: TextStyle(
                    color: colors.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.only(bottom: 16),
              child: child,
            ),
          ),
        ],
      ),
    );
  }
}

/// Merged sources + context chunks display.
/// Groups parent chunks by document name, with each document expandable to
/// reveal the context chunks used from it.
class _MergedSourcesContent extends StatefulWidget {
  final List<SourceAttribution> sources;
  final List<ParentChunk> parentChunks;

  const _MergedSourcesContent({
    required this.sources,
    required this.parentChunks,
  });

  @override
  State<_MergedSourcesContent> createState() => _MergedSourcesContentState();
}

class _MergedSourcesContentState extends State<_MergedSourcesContent> {
  final Set<String> _expandedDocs = {};

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    // Build a merged list of documents with their context chunks
    final Map<String, _DocSourceInfo> docMap = {};

    // Add sources
    for (final src in widget.sources) {
      final key = src.docName;
      docMap.putIfAbsent(key, () => _DocSourceInfo(docName: key));
      docMap[key]!.score = src.score > docMap[key]!.score
          ? src.score
          : docMap[key]!.score;
    }

    // Add parent chunks grouped by doc name
    for (final chunk in widget.parentChunks) {
      final key = chunk.docName;
      docMap.putIfAbsent(key, () => _DocSourceInfo(docName: key));
      docMap[key]!.chunks.add(chunk);
      if (chunk.score > docMap[key]!.score) {
        docMap[key]!.score = chunk.score;
      }
    }

    final docList = docMap.values.toList()
      ..sort((a, b) => b.score.compareTo(a.score));

    if (docList.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          'No source information available.',
          style: TextStyle(color: colors.textDim, fontSize: 13),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        children: docList.map((doc) => _buildDocItem(doc)).toList(),
      ),
    );
  }

  Widget _buildDocItem(_DocSourceInfo doc) {
    final colors = context.colors;
    final scheme = Theme.of(context).colorScheme;
    final isExpanded = _expandedDocs.contains(doc.docName);
    final isPdf = doc.docName.toLowerCase().endsWith('.pdf');
    final hasChunks = doc.chunks.isNotEmpty;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: scheme.secondary.withValues(alpha: 0.2),
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Document header (tap to expand)
          InkWell(
            onTap: hasChunks
                ? () => setState(() {
                    if (isExpanded) {
                      _expandedDocs.remove(doc.docName);
                    } else {
                      _expandedDocs.add(doc.docName);
                    }
                  })
                : null,
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                children: [
                  Icon(
                    isPdf
                        ? Icons.picture_as_pdf_rounded
                        : Icons.text_snippet_rounded,
                    size: 16,
                    color: isPdf ? colors.error : scheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      doc.docName,
                      style: TextStyle(
                        color: colors.textPrimary,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
                  _RelevanceBadge(score: doc.score),
                  if (hasChunks) ...[
                    const SizedBox(width: 6),
                    AnimatedRotation(
                      turns: isExpanded ? 0.5 : 0.0,
                      duration: const Duration(milliseconds: 200),
                      child: Icon(
                        Icons.keyboard_arrow_down_rounded,
                        size: 18,
                        color: colors.textDim,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),

          // Expanded context chunks
          if (isExpanded && hasChunks)
            AnimatedCrossFade(
              firstChild: const SizedBox.shrink(),
              secondChild: _buildChunkList(doc.chunks),
              crossFadeState: isExpanded
                  ? CrossFadeState.showSecond
                  : CrossFadeState.showFirst,
              duration: const Duration(milliseconds: 200),
            ),
        ],
      ),
    );
  }

  Widget _buildChunkList(List<ParentChunk> chunks) {
    final colors = context.colors;
    final scheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Divider(color: colors.divider, height: 1),
          const SizedBox(height: 6),
          Text(
            'Context used · ${chunks.length} chunk${chunks.length > 1 ? 's' : ''}',
            style: TextStyle(
              color: scheme.primary.withValues(alpha: 0.7),
              fontSize: 11,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 6),
          ...chunks.map((chunk) => _buildChunkItem(chunk)),
        ],
      ),
    );
  }

  Widget _buildChunkItem(ParentChunk chunk) {
    final colors = context.colors;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Container(
        constraints: const BoxConstraints(maxHeight: 160),
        decoration: BoxDecoration(
          color: colors.surfaceLight.withValues(alpha: 0.62),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: colors.divider, width: 1),
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(10),
          child: Text(
            chunk.text,
            style: TextStyle(
              color: colors.textSecondary,
              fontSize: 11,
              height: 1.5,
            ),
          ),
        ),
      ),
    );
  }
}

/// Internal data class to group source info by document.
class _DocSourceInfo {
  final String docName;
  double score;
  final List<ParentChunk> chunks;

  _DocSourceInfo({required this.docName, List<ParentChunk>? chunks})
    : score = 0.0,
      chunks = chunks ?? [];
}

/// Relevance badge widget used in the merged sources display.
class _RelevanceBadge extends StatelessWidget {
  final double score;
  const _RelevanceBadge({required this.score});

  @override
  Widget build(BuildContext context) {
    final label = _label(score);
    final color = _color(context, score);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 9.5,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.3,
        ),
      ),
    );
  }

  String _label(double s) {
    if (s >= 0.018) return 'HIGH';
    if (s >= 0.010) return 'MED';
    if (s >= 0.004) return 'LOW';
    return 'WEAK';
  }

  Color _color(BuildContext context, double s) {
    final colors = context.colors;
    if (s >= 0.018) return colors.success;
    if (s >= 0.010) return Theme.of(context).colorScheme.primary;
    if (s >= 0.004) return colors.warning;
    return colors.textDim;
  }
}
