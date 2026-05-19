import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../controllers/chat_controller.dart';
import '../theme/app_theme.dart';
import '../widgets/chat_app_bar.dart';
import '../widgets/chat_input_bar.dart';
import '../widgets/chat_message_list.dart';
import '../widgets/document_drawer.dart';
import '../widgets/init_overlay.dart';
import '../widgets/upload_banner.dart';
import 'settings_screen.dart';
import '../utils/top_snackbar.dart';

class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key});

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
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

  void _onPromptTapped(String label) {
    _controller.text = label;
    _controller.selection = TextSelection.fromPosition(
      TextPosition(offset: label.length),
    );
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
                ChatAppBar(
                  chatState: chatState,
                  onOpenDocuments: () =>
                      _scaffoldKey.currentState?.openEndDrawer(),
                  onOpenSettings: _openSettings,
                  onToggleRagMode: () => ref
                      .read(chatControllerProvider.notifier)
                      .toggleRagMode(),
                  onResponseStyleChanged: (style) => ref
                      .read(chatControllerProvider.notifier)
                      .setResponseStyle(style),
                ),
                // Upload status banner
                if (chatState.isUploading)
                  UploadBanner(uploadStatus: chatState.uploadStatus),
                Expanded(
                  child: ChatMessageList(
                    messages: chatState.messages,
                    initDone: chatState.initDone,
                    ragMode: chatState.ragMode,
                    scrollController: _scrollController,
                    onPromptTapped: _onPromptTapped,
                  ),
                ),
                ChatInputBar(
                  controller: _controller,
                  enabled: chatState.initDone,
                  isGenerating: chatState.isGenerating,
                  ragMode: chatState.ragMode,
                  activeDocumentName: chatState.activeDocumentName,
                  onSend: _sendMessage,
                  onStop: _stopGeneration,
                  onAddFile: () => ref
                      .read(chatControllerProvider.notifier)
                      .pickAndUploadFile(),
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
}
