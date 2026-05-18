import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// Collapsible card showing the raw Qwen3 <think>…</think> reasoning block.
/// Only rendered when [thinkingText] is non-empty.
class ThinkingDropdown extends StatefulWidget {
  final String thinkingText;

  const ThinkingDropdown({super.key, required this.thinkingText});

  @override
  State<ThinkingDropdown> createState() => _ThinkingDropdownState();
}

class _ThinkingDropdownState extends State<ThinkingDropdown>
    with SingleTickerProviderStateMixin {
  bool _expanded = false;
  late final AnimationController _controller;
  late final Animation<double> _fadeAnim;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
    );
    _fadeAnim = CurvedAnimation(parent: _controller, curve: Curves.easeIn);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _toggle() {
    setState(() => _expanded = !_expanded);
    if (_expanded) {
      _controller.forward();
    } else {
      _controller.reverse();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.thinkingText.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(left: 50, right: 48, top: 2, bottom: 4),
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: const Color(0xFFFFB946).withValues(alpha: 0.22),
            width: 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Header ──────────────────────────────────────────────────
            InkWell(
              onTap: _toggle,
              borderRadius: BorderRadius.circular(12),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                child: Row(
                  children: [
                    // Animated brain icon
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 200),
                      child: Icon(
                        _expanded
                            ? Icons.psychology_rounded
                            : Icons.psychology_outlined,
                        key: ValueKey(_expanded),
                        size: 15,
                        color: AppColors.warning.withValues(alpha: 0.85),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      'Model Thinking',
                      style: TextStyle(
                        color: AppColors.warning.withValues(alpha: 0.9),
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        letterSpacing: 0.1,
                      ),
                    ),
                    const SizedBox(width: 6),
                    // Token count hint
                    Text(
                      '· ${_tokenCount(widget.thinkingText)} tokens',
                      style: TextStyle(
                        color: AppColors.textDim,
                        fontSize: 10,
                      ),
                    ),
                    const Spacer(),
                    AnimatedRotation(
                      turns: _expanded ? 0.5 : 0.0,
                      duration: const Duration(milliseconds: 220),
                      child: Icon(
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
              duration: const Duration(milliseconds: 220),
              crossFadeState: _expanded
                  ? CrossFadeState.showSecond
                  : CrossFadeState.showFirst,
              firstChild: const SizedBox.shrink(),
              secondChild: FadeTransition(
                opacity: _fadeAnim,
                child: _buildBody(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(
          color: AppColors.divider,
          height: 1,
          indent: 12,
          endIndent: 12,
        ),
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 280),
          child: Stack(
            children: [
              Scrollbar(
                thumbVisibility: true,
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
                  child: Text(
                    widget.thinkingText,
                    style: const TextStyle(
                      color: Color(0xFFAAAAAA),
                      fontSize: 11.5,
                      height: 1.55,
                      fontFamily: 'monospace',
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ),
              ),
              // Bottom fade to indicate more content below
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: IgnorePointer(
                  child: Container(
                    height: 24,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          AppColors.surface.withValues(alpha: 0.0),
                          AppColors.surface.withValues(alpha: 0.85),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// Rough token count: ~4 chars per token.
  String _tokenCount(String text) {
    final count = (text.length / 4).round();
    return count >= 1000 ? '${(count / 1000).toStringAsFixed(1)}k' : '$count';
  }
}
