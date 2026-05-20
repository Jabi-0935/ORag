import 'package:flutter/material.dart';

import '../models/chat_message.dart';
import '../theme/app_theme.dart';

/// Collapsible card showing parent chunks retrieved for a RAG query.
class ContextChunksCard extends StatefulWidget {
  final List<ParentChunk> chunks;
  final bool initiallyExpanded;

  const ContextChunksCard({
    super.key,
    required this.chunks,
    this.initiallyExpanded = false,
  });

  @override
  State<ContextChunksCard> createState() => _ContextChunksCardState();
}

class _ContextChunksCardState extends State<ContextChunksCard> {
  late bool _expanded = widget.initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    if (widget.chunks.isEmpty) return const SizedBox.shrink();

    final colors = context.colors;
    final scheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Container(
        decoration: BoxDecoration(
          color: colors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: scheme.primary.withValues(alpha: 0.18),
            width: 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            InkWell(
              onTap: () => setState(() => _expanded = !_expanded),
              borderRadius: BorderRadius.circular(12),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 9,
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.article_outlined,
                      size: 14,
                      color: scheme.primary.withValues(alpha: 0.75),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      'Context Used',
                      style: TextStyle(
                        color: scheme.primary.withValues(alpha: 0.85),
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '- ${widget.chunks.length} chunk${widget.chunks.length > 1 ? 's' : ''}',
                      style: TextStyle(color: colors.textDim, fontSize: 10),
                    ),
                    const Spacer(),
                    AnimatedRotation(
                      turns: _expanded ? 0.5 : 0.0,
                      duration: const Duration(milliseconds: 200),
                      child: Icon(
                        Icons.keyboard_arrow_down_rounded,
                        size: 18,
                        color: colors.textDim,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            AnimatedCrossFade(
              duration: const Duration(milliseconds: 200),
              crossFadeState: _expanded
                  ? CrossFadeState.showSecond
                  : CrossFadeState.showFirst,
              firstChild: const SizedBox.shrink(),
              secondChild: _buildChunks(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildChunks() {
    final colors = context.colors;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Divider(color: colors.divider, height: 1),
          const SizedBox(height: 8),
          ...widget.chunks.asMap().entries.map((entry) {
            final idx = entry.key;
            final chunk = entry.value;
            return _buildChunkItem(chunk, idx);
          }),
        ],
      ),
    );
  }

  Widget _buildChunkItem(ParentChunk chunk, int index) {
    final colors = context.colors;
    final scheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                chunk.docName.toLowerCase().endsWith('.pdf')
                    ? Icons.picture_as_pdf_rounded
                    : Icons.text_snippet_rounded,
                size: 12,
                color: scheme.primary.withValues(alpha: 0.7),
              ),
              const SizedBox(width: 5),
              Expanded(
                child: Text(
                  chunk.docName,
                  style: TextStyle(
                    color: scheme.primary.withValues(alpha: 0.85),
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 6),
              _RelevanceBadge(score: chunk.score),
            ],
          ),
          const SizedBox(height: 5),
          Container(
            constraints: const BoxConstraints(maxHeight: 200),
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
          if (index < widget.chunks.length - 1) ...[
            const SizedBox(height: 6),
            Divider(color: colors.divider, height: 1),
          ],
        ],
      ),
    );
  }
}

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
