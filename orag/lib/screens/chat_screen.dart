import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../controllers/chat_controller.dart';
import '../models/chat_message.dart';
import '../theme/app_theme.dart';
import '../widgets/chat_bubble.dart';
import '../widgets/chat_input_bar.dart';
import '../widgets/document_drawer.dart';
import '../widgets/init_overlay.dart';
import 'settings_screen.dart';
import '../utils/top_snackbar.dart';
import '../widgets/typing_indicator.dart';

class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key});

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen>
    with TickerProviderStateMixin {
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  
  // Mode badge pulse animation
  late final AnimationController _modePulseController;
  late final Animation<double> _modePulseAnimation;
  bool? _prevRagMode; // track previous mode to trigger pulse

  @override
  void initState() {
    super.initState();
    _modePulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 350),
    );
    _modePulseAnimation = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 1.0, end: 1.15), weight: 40),
      TweenSequenceItem(tween: Tween(begin: 1.15, end: 1.0), weight: 60),
    ]).animate(CurvedAnimation(
      parent: _modePulseController,
      curve: Curves.easeOut,
    ));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(chatControllerProvider.notifier).startInit();
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _controller.dispose();
    _modePulseController.dispose();
    super.dispose();
  }

  // ---- Actions ----

  void _sendMessage() {
    String text = _controller.text.trim();
    final ragMode = ref.read(chatControllerProvider).ragMode;
    final docName = ref.read(chatControllerProvider).activeDocumentName;

    if (text.isEmpty) {
      if (ragMode && docName != null) {
        text = 'Tell me about $docName and suggest some questions I can ask.';
      } else {
        return;
      }
    }
    HapticFeedback.lightImpact();
    _controller.clear();
    ref.read(chatControllerProvider.notifier).submitQuery(text);
    _scrollToBottom();
  }

  Future<void> _stopGeneration() async {
    await ref.read(chatControllerProvider.notifier).stopGeneration();
  }

  Future<void> _clearMemory() async {
    await ref.read(chatControllerProvider.notifier).clearMemory();
  }

  void _openSettings() {
    final ctrl = ref.read(chatControllerProvider.notifier);
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SettingsScreen(
          platform: ctrl.platform,
          onClearChat: _clearMemory,
        ),
      ),
    );
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
        );
      }
    });
  }

  // ---- Build ----

  @override
  Widget build(BuildContext context) {
    final chatState = ref.watch(chatControllerProvider);

    // Auto-scroll when streaming starts or message count changes
    ref.listen<ChatState>(chatControllerProvider, (prev, next) {
      if (next.isGenerating) {
        _scrollToBottom();
      }
      if ((prev?.messages.length ?? 0) != next.messages.length) {
        _scrollToBottom();
      }
    });

    // Show error banner via top notification (non-destructive)
    ref.listen<ChatState>(chatControllerProvider, (prev, next) {
      if (next.errorBanner != null && next.errorBanner != prev?.errorBanner) {
        showTopSnackBar(
          context,
          message: next.errorBanner!,
          backgroundColor: AppColors.error,
          duration: const Duration(seconds: 6),
        );
      }
    });

    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: AppColors.background,
      endDrawer: chatState.initDone
          ? DocumentDrawer(
              platform: ref.read(chatControllerProvider.notifier).platform,
            )
          : null,
      body: Stack(
        children: [
          // Main chat UI — only built after init completes
          if (chatState.initDone)
            Column(
              children: [
                _buildAppBar(chatState),
                // Upload status banner (above message list, not blocking input)
                if (chatState.isUploading)
                  _buildUploadBanner(chatState),
                Expanded(child: _buildMessageList(chatState)),
                ChatInputBar(
                  controller: _controller,
                  enabled: chatState.initDone,
                  isGenerating: chatState.isGenerating,
                  ragMode: chatState.ragMode,
                  activeDocumentName: chatState.activeDocumentName,
                  onSend: _sendMessage,
                  onStop: _stopGeneration,
                  onAddFile: () => ref.read(chatControllerProvider.notifier).pickAndUploadFile(),
                  isUploading: chatState.isUploading,
                ),
              ],
            ),

          // Init overlay — covers the entire screen
          if (!chatState.initDone)
            Positioned.fill(
              child: InitOverlay(
                status: chatState.initStatus,
                onRetry: () {
                  ref.read(chatControllerProvider.notifier).startInit();
                },
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildAppBar(ChatState chatState) {
    return Container(
      padding: EdgeInsets.only(
        top: MediaQuery.of(context).padding.top + 8,
        left: 16,
        right: 4,
        bottom: 12,
      ),
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(
          bottom: BorderSide(color: AppColors.divider, width: 1),
        ),
      ),
      child: Row(
        children: [
          // Logo
          Container(
            width: 36,
            height: 36,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              color: Colors.transparent,
            ),
            clipBehavior: Clip.antiAlias,
            child: Image.asset(
              'assets/logo.png',
              width: 36,
              height: 36,
              fit: BoxFit.contain,
              errorBuilder: (_, __, ___) => const SizedBox(
                width: 36, height: 36,
              ),
            ),
          ),
          const SizedBox(width: 12),
          // Title + mode badge
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'O-RAG',
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                _buildModeBadge(chatState),
              ],
            ),
          ),

          // Documents button
          IconButton(
            icon: const Icon(Icons.folder_open_rounded, size: 21),
            tooltip: 'Documents',
            onPressed: () => _scaffoldKey.currentState?.openEndDrawer(),
            color: AppColors.textSecondary,
          ),

          // Settings button
          IconButton(
            icon: const Icon(Icons.settings_outlined, size: 21),
            tooltip: 'Settings',
            onPressed: _openSettings,
            color: AppColors.textSecondary,
          ),
        ],
      ),
    );
  }

  Widget _buildModeBadge(ChatState chatState) {
    final isRag = chatState.ragMode;
    
    // Trigger pulse when mode changes
    if (_prevRagMode != null && _prevRagMode != isRag) {
      _modePulseController.forward(from: 0.0);
    }
    _prevRagMode = isRag;

    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        ref.read(chatControllerProvider.notifier).toggleRagMode();
      },
      child: ScaleTransition(
        scale: _modePulseAnimation,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeInOut,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
          decoration: BoxDecoration(
            color: (isRag ? AppColors.secondary : AppColors.primary)
                .withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: (isRag ? AppColors.secondary : AppColors.primary)
                  .withValues(alpha: 0.35),
              width: 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                child: Icon(
                  isRag ? Icons.description_outlined : Icons.smart_toy_outlined,
                  key: ValueKey(isRag),
                  size: 13,
                  color: isRag ? AppColors.secondary : AppColors.primary,
                ),
              ),
              const SizedBox(width: 5),
              Flexible(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 200),
                  child: Text(
                    isRag
                        ? (chatState.activeDocumentName != null
                            ? chatState.activeDocumentName!.length > 18
                                ? '📄 ${chatState.activeDocumentName!.substring(0, 16)}…'
                                : '📄 ${chatState.activeDocumentName}'
                            : 'Document Mode')
                        : 'AI Chat',
                    key: ValueKey('mode_$isRag'),
                    style: TextStyle(
                      color: isRag ? AppColors.secondary : AppColors.primary,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }


  Widget _buildUploadBanner(ChatState chatState) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(alpha: 0.08),
        border: const Border(
          bottom: BorderSide(color: AppColors.divider, width: 1),
        ),
      ),
      child: Row(
        children: [
          const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: AppColors.primary,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              chatState.uploadStatus.isNotEmpty
                  ? chatState.uploadStatus
                  : 'Processing document…',
              style: const TextStyle(
                color: AppColors.primary,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMessageList(ChatState chatState) {
    if (chatState.messages.isEmpty && chatState.initDone) {
      return _buildEmptyState(chatState);
    }

    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.symmetric(vertical: 12),
      itemCount: chatState.messages.length,
      itemBuilder: (context, index) {
        final msg = chatState.messages[index];

        // System messages render as centered info cards
        if (msg.role == MessageRole.system) {
          return _buildSystemMessage(msg);
        }

        // If this is the AI message and it's streaming but empty, show typing indicator
        if (msg.isAssistant && msg.isStreaming && msg.isEmpty) {
          return const TypingIndicator();
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Slide+fade entrance animation for each message
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
                children: [
                  ChatBubble(message: msg),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildSystemMessage(ChatMessage msg) {
    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 32, vertical: 8),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: AppColors.surfaceLight.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: AppColors.divider,
            width: 1,
          ),
        ),
        child: Text(
          msg.text,
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: AppColors.textSecondary,
            fontSize: 13,
            height: 1.4,
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyState(ChatState chatState) {
    final isRag = chatState.ragMode;
    final prompts = isRag
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
          // Logo in empty state
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
              errorBuilder: (_, __, ___) => const SizedBox(
                width: 80, height: 80,
              ),
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
            isRag ? 'Ask anything about your document' : 'Start a conversation',
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
              children: prompts.map((label) => _promptChip(label)).toList(),
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
        _controller.text = label;
        _controller.selection = TextSelection.fromPosition(
          TextPosition(offset: label.length),
        );
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
