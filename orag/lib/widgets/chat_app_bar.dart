import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../controllers/chat_controller.dart';
import '../theme/app_theme.dart';

/// Premium frosted-glass top bar for the chat screen.
class ChatAppBar extends StatefulWidget {
  final ChatState chatState;
  final VoidCallback onOpenDocuments;
  final VoidCallback onOpenSettings;
  final VoidCallback onToggleRagMode;
  final ValueChanged<ResponseStyle> onResponseStyleChanged;

  const ChatAppBar({
    super.key,
    required this.chatState,
    required this.onOpenDocuments,
    required this.onOpenSettings,
    required this.onToggleRagMode,
    required this.onResponseStyleChanged,
  });

  @override
  State<ChatAppBar> createState() => _ChatAppBarState();
}

class _ChatAppBarState extends State<ChatAppBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulseCtrl;
  late final Animation<double> _pulseAnim;
  bool? _prevRagMode;

  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 350),
    );
    _pulseAnim = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 1.0, end: 1.15), weight: 40),
      TweenSequenceItem(tween: Tween(begin: 1.15, end: 1.0), weight: 60),
    ]).animate(CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeOut));
  }

  @override
  void dispose() {
    _pulseCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = widget.chatState;
    final colors = context.colors;
    final scheme = Theme.of(context).colorScheme;

    return ClipRRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: EdgeInsets.only(
                top: MediaQuery.of(context).padding.top + 8,
                left: 14,
                right: 10,
                bottom: 10,
              ),
              decoration: BoxDecoration(color: colors.glassBackground),
              child: Row(
                children: [
                  // Logo
                  _buildLogo(),
                  const SizedBox(width: 8),

                  // "O-RAG · Concise" dropdown — takes remaining space
                  Expanded(child: _buildTitle(cs)),

                  // Mode toggle
                  _buildModeToggle(cs),

                  const SizedBox(width: 6),

                  // Documents
                  _buildIconBtn(
                    icon: Icons.folder_open_rounded,
                    tooltip: 'Documents',
                    onPressed: widget.onOpenDocuments,
                  ),
                  const SizedBox(width: 4),

                  // Settings
                  _buildIconBtn(
                    icon: Icons.settings_outlined,
                    tooltip: 'Settings',
                    onPressed: widget.onOpenSettings,
                  ),
                ],
              ),
            ),
            // Glowing gradient bottom edge
            Container(
              height: 1.5,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    scheme.primary.withValues(alpha: 0.0),
                    scheme.primary.withValues(alpha: 0.34),
                    scheme.secondary.withValues(alpha: 0.28),
                    scheme.secondary.withValues(alpha: 0.0),
                  ],
                  stops: const [0.0, 0.35, 0.65, 1.0],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Logo ──────────────────────────────────────────────────────────────

  Widget _buildLogo() {
    return Container(
      width: 34,
      height: 34,
      alignment: Alignment.center,
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(9)),
      clipBehavior: Clip.antiAlias,
      child: Image.asset(
        'assets/logo.png',
        width: 34,
        height: 34,
        fit: BoxFit.contain,
        errorBuilder: (context, error, stackTrace) =>
            const SizedBox(width: 34, height: 34),
      ),
    );
  }

  // ── Title: "O-RAG · Concise ▼" — tappable dropdown ───────────────────

  Widget _buildTitle(ChatState cs) {
    final colors = context.colors;
    final scheme = Theme.of(context).colorScheme;
    final style = cs.responseStyle;
    final isConcise = style == ResponseStyle.concise;
    final styleName = isConcise ? 'Concise' : 'Detailed';
    final styleColor = isConcise ? colors.warning : scheme.secondary;

    return PopupMenuButton<ResponseStyle>(
      onSelected: (selected) {
        HapticFeedback.selectionClick();
        widget.onResponseStyleChanged(selected);
      },
      offset: const Offset(-15, 44),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      color: colors.surface,
      elevation: 8,
      itemBuilder: (_) => [
        _styleMenuItem(
          ResponseStyle.concise,
          Icons.bolt_rounded,
          'Concise',
          'Fast, direct answers',
          isConcise,
        ),
        _styleMenuItem(
          ResponseStyle.detailed,
          Icons.auto_awesome_rounded,
          'Detailed',
          'Thorough, comprehensive',
          !isConcise,
        ),
      ],
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // "O-RAG"
          Text(
            'O-RAG',
            style: TextStyle(
              color: colors.textPrimary,
              fontSize: 17,
              fontWeight: FontWeight.w700,
            ),
          ),
          // Dot separator
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              '·',
              style: TextStyle(
                color: colors.textDim.withValues(alpha: 0.5),
                fontSize: 17,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          // Style name (animated swap)
          Flexible(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              transitionBuilder: (child, anim) => FadeTransition(
                opacity: anim,
                child: SlideTransition(
                  position: Tween<Offset>(
                    begin: const Offset(0, 0.25),
                    end: Offset.zero,
                  ).animate(anim),
                  child: child,
                ),
              ),
              child: Text(
                styleName,
                key: ValueKey(styleName),
                style: TextStyle(
                  color: styleColor,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
              ),
            ),
          ),
          const SizedBox(width: 2),
          Icon(
            Icons.keyboard_arrow_down_rounded,
            size: 18,
            color: colors.textDim.withValues(alpha: 0.45),
          ),
        ],
      ),
    );
  }

  PopupMenuEntry<ResponseStyle> _styleMenuItem(
    ResponseStyle value,
    IconData icon,
    String label,
    String subtitle,
    bool isSelected,
  ) {
    final colors = context.colors;
    final scheme = Theme.of(context).colorScheme;
    return PopupMenuItem<ResponseStyle>(
      value: value,
      child: Row(
        children: [
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: (isSelected ? scheme.primary : colors.textDim).withValues(
                alpha: 0.1,
              ),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(
              icon,
              size: 16,
              color: isSelected ? scheme.primary : colors.textDim,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    color: colors.textPrimary,
                    fontSize: 13,
                    fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                  ),
                ),
                Text(
                  subtitle,
                  style: TextStyle(color: colors.textDim, fontSize: 11),
                ),
              ],
            ),
          ),
          if (isSelected)
            Icon(Icons.check_rounded, size: 18, color: scheme.primary),
        ],
      ),
    );
  }

  // ── Icon button with subtle glow on press ────────────────────────────

  Widget _buildIconBtn({
    required IconData icon,
    required String tooltip,
    required VoidCallback onPressed,
  }) {
    final colors = context.colors;
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(10),
          splashColor: colors.glowPrimary,
          highlightColor: scheme.primary.withValues(alpha: 0.08),
          child: Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              color: colors.surfaceLight.withValues(alpha: 0.45),
            ),
            child: Icon(icon, size: 18, color: colors.textSecondary),
          ),
        ),
      ),
    );
  }

  // ── Mode toggle: Chat / Doc segmented pill ───────────────────────────

  Widget _buildModeToggle(ChatState cs) {
    final colors = context.colors;
    final scheme = Theme.of(context).colorScheme;
    final isRag = cs.ragMode;

    if (_prevRagMode != null && _prevRagMode != isRag) {
      _pulseCtrl.forward(from: 0.0);
    }
    _prevRagMode = isRag;

    String ragLabel = 'Doc';
    if (isRag && cs.activeDocumentName != null) {
      final name = cs.activeDocumentName!;
      ragLabel = name.length > 6 ? '${name.substring(0, 5)}…' : name;
    }

    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        widget.onToggleRagMode();
      },
      child: ScaleTransition(
        scale: _pulseAnim,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeInOut,
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            color: colors.surfaceLight.withValues(alpha: 0.56),
            borderRadius: BorderRadius.circular(11),
            border: Border.all(
              color: colors.divider.withValues(alpha: 0.72),
              width: 1,
            ),
            boxShadow: [
              BoxShadow(
                color: (isRag ? scheme.secondary : scheme.primary).withValues(
                  alpha: 0.08,
                ),
                blurRadius: 10,
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _segment(
                icon: Icons.smart_toy_outlined,
                label: 'Chat',
                isActive: !isRag,
                color: scheme.primary,
              ),
              const SizedBox(width: 2),
              _segment(
                icon: Icons.description_outlined,
                label: ragLabel,
                isActive: isRag,
                color: scheme.secondary,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _segment({
    required IconData icon,
    required String label,
    required bool isActive,
    required Color color,
  }) {
    final colors = context.colors;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeInOut,
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
      decoration: BoxDecoration(
        color: isActive ? color.withValues(alpha: 0.15) : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        boxShadow: isActive
            ? [BoxShadow(color: color.withValues(alpha: 0.2), blurRadius: 6)]
            : [],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: isActive ? color : colors.textDim),
          const SizedBox(width: 3),
          Text(
            label,
            style: TextStyle(
              color: isActive ? color : colors.textDim,
              fontSize: 11,
              fontWeight: isActive ? FontWeight.w600 : FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}
