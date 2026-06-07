import 'package:flutter/material.dart';

import '../models/chat_message.dart';
import '../theme/app_theme.dart';

/// Collapsible card showing which documents were used to answer a RAG query.
class SourceCard extends StatefulWidget {
  final List<SourceAttribution> sources;
  final bool initiallyExpanded;

  const SourceCard({
    super.key,
    required this.sources,
    this.initiallyExpanded = false,
  });

  @override
  State<SourceCard> createState() => _SourceCardState();
}

class _SourceCardState extends State<SourceCard> {
  late bool _expanded = widget.initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    if (widget.sources.isEmpty) return const SizedBox.shrink();

    final colors = context.colors;
    final scheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Container(
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
            InkWell(
              onTap: () => setState(() => _expanded = !_expanded),
              borderRadius: BorderRadius.circular(12),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.source_rounded,
                      size: 14,
                      color: scheme.secondary.withValues(alpha: 0.72),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '${widget.sources.length} source${widget.sources.length > 1 ? 's' : ''} used',
                      style: TextStyle(
                        color: scheme.secondary.withValues(alpha: 0.86),
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
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
              firstChild: const SizedBox.shrink(),
              secondChild: _buildSources(),
              crossFadeState: _expanded
                  ? CrossFadeState.showSecond
                  : CrossFadeState.showFirst,
              duration: const Duration(milliseconds: 200),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSources() {
    final colors = context.colors;
    final scheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Divider(color: colors.divider, height: 1),
          const SizedBox(height: 8),
          ...widget.sources.map((src) {
            final relevance = _relevanceColor(context, src.score);
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        src.docName.endsWith('.pdf')
                            ? Icons.picture_as_pdf_rounded
                            : Icons.text_snippet_rounded,
                        size: 13,
                        color: scheme.primary,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          src.docName,
                          style: TextStyle(
                            color: scheme.primary,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: relevance.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          _relevanceLabel(src.score),
                          style: TextStyle(
                            color: relevance,
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    src.chunkText,
                    style: TextStyle(
                      color: colors.textDim,
                      fontSize: 11,
                      height: 1.4,
                    ),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }
}

String _relevanceLabel(double score) {
  if (score >= 0.018) return 'High';
  if (score >= 0.010) return 'Medium';
  if (score >= 0.004) return 'Low';
  return 'Weak';
}

Color _relevanceColor(BuildContext context, double score) {
  final colors = context.colors;
  if (score >= 0.018) return colors.success;
  if (score >= 0.010) return Theme.of(context).colorScheme.primary;
  if (score >= 0.004) return colors.warning;
  return colors.textDim;
}
