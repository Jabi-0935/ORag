import 'package:flutter/material.dart';
import '../models/chat_message.dart';
import '../theme/app_theme.dart';

/// Collapsible card showing the parent chunks that were retrieved and fed
/// to the model for a RAG query (Document mode only).
/// Only rendered when [chunks] is non-empty.
class ContextChunksCard extends StatefulWidget {
  final List<ParentChunk> chunks;

  const ContextChunksCard({super.key, required this.chunks});

  @override
  State<ContextChunksCard> createState() => _ContextChunksCardState();
}

class _ContextChunksCardState extends State<ContextChunksCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    if (widget.chunks.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(left: 50, right: 48, top: 2, bottom: 4),
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: AppColors.primary.withValues(alpha: 0.18),
            width: 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Header ──────────────────────────────────────────────────
            InkWell(
              onTap: () => setState(() => _expanded = !_expanded),
              borderRadius: BorderRadius.circular(12),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                child: Row(
                  children: [
                    Icon(
                      Icons.article_outlined,
                      size: 14,
                      color: AppColors.primary.withValues(alpha: 0.75),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      'Context Used',
                      style: TextStyle(
                        color: AppColors.primary.withValues(alpha: 0.85),
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '· ${widget.chunks.length} chunk${widget.chunks.length > 1 ? 's' : ''}',
                      style: const TextStyle(
                        color: AppColors.textDim,
                        fontSize: 10,
                      ),
                    ),
                    const Spacer(),
                    AnimatedRotation(
                      turns: _expanded ? 0.5 : 0.0,
                      duration: const Duration(milliseconds: 200),
                      child: const Icon(
                        Icons.keyboard_arrow_down_rounded,
                        size: 18,
                        color: AppColors.textDim,
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // ── Expanded body ────────────────────────────────────────────
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Divider(color: AppColors.divider, height: 1),
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
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Doc name + relevance badge
          Row(
            children: [
              Icon(
                chunk.docName.toLowerCase().endsWith('.pdf')
                    ? Icons.picture_as_pdf_rounded
                    : Icons.text_snippet_rounded,
                size: 12,
                color: AppColors.primary.withValues(alpha: 0.7),
              ),
              const SizedBox(width: 5),
              Expanded(
                child: Text(
                  chunk.docName,
                  style: TextStyle(
                    color: AppColors.primary.withValues(alpha: 0.85),
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
          // Full chunk text in a scrollable container
          Container(
            constraints: const BoxConstraints(maxHeight: 200),
            decoration: BoxDecoration(
              color: AppColors.surfaceLight.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: AppColors.divider,
                width: 1,
              ),
            ),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(10),
              child: Text(
                chunk.text,
                style: const TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 11,
                  height: 1.5,
                ),
              ),
            ),
          ),
          if (index < widget.chunks.length - 1) ...[
            const SizedBox(height: 6),
            const Divider(color: AppColors.divider, height: 1),
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
    final color = _color(score);
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

  Color _color(double s) {
    if (s >= 0.018) return AppColors.success;
    if (s >= 0.010) return AppColors.primary;
    if (s >= 0.004) return AppColors.warning;
    return AppColors.textDim;
  }
}
