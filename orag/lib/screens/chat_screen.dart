import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../controllers/chat_controller.dart';
import '../models/chat_message.dart';
import '../services/platform_service.dart';
import '../theme/app_theme.dart';
import '../widgets/chat_bubble.dart';
import '../widgets/chat_input_bar.dart';
import '../widgets/init_overlay.dart';
import 'settings_screen.dart';
import '../widgets/source_card.dart';
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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(chatControllerProvider.notifier).startInit();
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _controller.dispose();
    super.dispose();
  }

  // ---- Actions ----

  void _sendMessage() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
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

    // Show error banner via SnackBar (non-destructive)
    ref.listen<ChatState>(chatControllerProvider, (prev, next) {
      if (next.errorBanner != null && next.errorBanner != prev?.errorBanner) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(next.errorBanner!),
            backgroundColor: AppColors.error,
            action: SnackBarAction(
              label: 'Dismiss',
              textColor: Colors.white,
              onPressed: () {
                ref.read(chatControllerProvider.notifier).dismissError();
              },
            ),
            duration: const Duration(seconds: 6),
          ),
        );
      }
    });

    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: AppColors.background,
      body: Stack(
        children: [
          // Main chat UI — only built after init completes
          if (chatState.initDone)
            Column(
              children: [
                _buildAppBar(chatState),
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
                  uploadStatus: chatState.uploadStatus,
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
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        ref.read(chatControllerProvider.notifier).toggleRagMode();
      },
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
            Icon(
              isRag ? Icons.description_outlined : Icons.smart_toy_outlined,
              size: 13,
              color: isRag ? AppColors.secondary : AppColors.primary,
            ),
            const SizedBox(width: 5),
            Text(
              isRag ? 'Document Mode' : 'AI Chat',
              style: TextStyle(
                color: isRag ? AppColors.secondary : AppColors.primary,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
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
            ChatBubble(message: msg),
            // Show source attribution card below AI messages with sources
            if (msg.isAssistant && msg.hasSources && !msg.isStreaming)
              SourceCard(sources: msg.sources),
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
        ],
      ),
    );
  }
}
