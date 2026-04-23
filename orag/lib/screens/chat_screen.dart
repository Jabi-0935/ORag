import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../controllers/chat_controller.dart';
import '../services/platform_service.dart';
import '../theme/app_theme.dart';
import '../widgets/chat_bubble.dart';
import '../widgets/chat_input_bar.dart';
import '../widgets/document_drawer.dart';
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

    // Auto-scroll when messages update during streaming
    if (chatState.isGenerating) {
      _scrollToBottom();
    }

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
      backgroundColor: const Color(0xFF040123),
      endDrawer: chatState.initDone
          ? DocumentDrawer(
              platform:
                  ref.read(chatControllerProvider.notifier).platform)
          : null,
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
                  onSend: _sendMessage,
                  onStop: _stopGeneration,
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
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Image.asset(
              'assets/logo.png',
              width: 36,
              height: 36,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => const SizedBox(
                width: 36, height: 36,
              ),
            ),
          ),
          const SizedBox(width: 12),
          // Title + mode subtitle
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
                Text(
                  chatState.ragMode ? 'Document Q&A Mode' : 'Chat Mode',
                  style: const TextStyle(
                    color: AppColors.textDim,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),

          // RAG toggle
          _buildModeToggle(chatState),

          // Documents button
          IconButton(
            icon: const Icon(Icons.folder_outlined, size: 21),
            tooltip: 'Documents',
            onPressed: () =>
                _scaffoldKey.currentState?.openEndDrawer(),
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

  Widget _buildModeToggle(ChatState chatState) {
    return GestureDetector(
      onTap: chatState.isGenerating
          ? null
          : () => ref.read(chatControllerProvider.notifier).toggleRagMode(),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: chatState.ragMode
              ? AppColors.secondary.withValues(alpha: 0.15)
              : AppColors.primary.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: chatState.ragMode
                ? AppColors.secondary.withValues(alpha: 0.3)
                : AppColors.primary.withValues(alpha: 0.2),
            width: 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              chatState.ragMode
                  ? Icons.description_rounded
                  : Icons.chat_rounded,
              size: 14,
              color: chatState.ragMode
                  ? AppColors.secondary
                  : AppColors.primary,
            ),
            const SizedBox(width: 4),
            Text(
              chatState.ragMode ? 'RAG' : 'Chat',
              style: TextStyle(
                color: chatState.ragMode
                    ? AppColors.secondary
                    : AppColors.primary,
                fontSize: 12,
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
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color:
                      (chatState.ragMode ? AppColors.secondary : AppColors.primary)
                          .withValues(alpha: 0.15),
                  blurRadius: 30,
                  spreadRadius: 5,
                ),
              ],
            ),
            child: ClipOval(
              child: Image.asset(
                'assets/logo.png',
                width: 80,
                height: 80,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => const SizedBox(
                  width: 80, height: 80,
                ),
              ),
            ),
          ),
          const SizedBox(height: 20),
          Text(
            chatState.ragMode
                ? 'Ask about your documents'
                : 'Ask me anything',
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontSize: 18,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            chatState.ragMode
                ? 'Upload documents via 📁 then ask questions'
                : 'Your offline AI assistant is ready',
            style: const TextStyle(
              color: AppColors.textDim,
              fontSize: 14,
            ),
          ),
        ],
      ),
    );
  }
}
