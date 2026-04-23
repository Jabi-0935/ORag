import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../models/chat_message.dart';
import '../services/platform_service.dart';

// ---- State ----

class ChatState {
  final List<ChatMessage> messages;
  final bool isGenerating;
  final bool ragMode;
  final InitStatus initStatus;
  final bool initDone;
  final String? errorBanner; // non-destructive error display

  const ChatState({
    this.messages = const [],
    this.isGenerating = false,
    this.ragMode = false,
    this.initStatus = const InitStatus(),
    this.initDone = false,
    this.errorBanner,
  });

  ChatState copyWith({
    List<ChatMessage>? messages,
    bool? isGenerating,
    bool? ragMode,
    InitStatus? initStatus,
    bool? initDone,
    String? errorBanner,
    bool clearError = false,
  }) {
    return ChatState(
      messages: messages ?? this.messages,
      isGenerating: isGenerating ?? this.isGenerating,
      ragMode: ragMode ?? this.ragMode,
      initStatus: initStatus ?? this.initStatus,
      initDone: initDone ?? this.initDone,
      errorBanner: clearError ? null : (errorBanner ?? this.errorBanner),
    );
  }
}

// ---- Controller ----

class ChatController extends Notifier<ChatState> {
  final PlatformService _platform = PlatformService();
  StreamSubscription<String>? _chatSub;
  Timer? _initTimeoutTimer;
  bool _isInitializing = false;

  static const _initTimeoutDuration = Duration(minutes: 5);

  PlatformService get platform => _platform;

  @override
  ChatState build() {
    ref.onDispose(() {
      _chatSub?.cancel();
      _initTimeoutTimer?.cancel();
    });
    return const ChatState();
  }

  // ---- Init flow ----

  Future<void> startInit() async {
    if (_isInitializing) return;
    _isInitializing = true;

    state = state.copyWith(
      initStatus: const InitStatus(
        state: InitState.idle,
        message: 'Preparing the AI engine…',
      ),
      initDone: false,
      clearError: true,
    );

    try {
      final modelPath = (await getExternalStorageDirectory())?.path;

      _platform.initPython(modelPath ?? '').listen(
        (status) {
          state = state.copyWith(initStatus: status);
          if (status.isReady) {
            state = state.copyWith(initDone: true);
            _isInitializing = false;
            _initTimeoutTimer?.cancel();
          }
        },
        onDone: () {
          _isInitializing = false;
        },
        onError: (e) {
          _isInitializing = false;
          state = state.copyWith(
            initStatus: InitStatus(
              state: InitState.error,
              progress: 1.0,
              message: 'Initialization failed: $e',
            ),
          );
          _initTimeoutTimer?.cancel();
        },
      );

      // Start a timeout timer — replaces the old hardcoded 120-iteration loop
      _initTimeoutTimer?.cancel();
      _initTimeoutTimer = Timer(_initTimeoutDuration, () {
        if (!state.initDone) {
          _isInitializing = false;
          state = state.copyWith(
            initStatus: const InitStatus(
              state: InitState.error,
              progress: 1.0,
              message: 'Initialization timed out. Please restart the app.',
            ),
          );
        }
      });
    } catch (e) {
      _isInitializing = false;
      state = state.copyWith(
        initStatus: InitStatus(
          state: InitState.error,
          progress: 1.0,
          message: 'Failed to start: $e',
        ),
      );
    }
  }

  // ---- Mode toggle ----

  void toggleRagMode() {
    if (!state.isGenerating) {
      state = state.copyWith(ragMode: !state.ragMode);
    }
  }

  // ---- Unified query (Tasks 2.2 + 2.3) ----

  void submitQuery(String text) {
    if (state.isGenerating || !state.initDone) return;
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;

    if (state.ragMode) {
      _submitRag(trimmed);
    } else {
      _submitChat(trimmed);
    }
  }

  void _submitChat(String text) {
    final userMsg = ChatMessage(role: MessageRole.user, text: text);
    final aiMsg = ChatMessage(
      role: MessageRole.assistant,
      text: '',
      isStreaming: true,
    );

    final msgs = [...state.messages, userMsg, aiMsg];
    state = state.copyWith(
      messages: msgs,
      isGenerating: true,
      clearError: true,
    );

    _chatSub?.cancel();
    _chatSub = _platform.chatStream(text).listen(
      (token) {
        aiMsg.text += token;
        state = state.copyWith(messages: [...state.messages]);
      },
      onError: (error) {
        debugPrint('[ChatController] chatStream error: $error');
        aiMsg.isStreaming = false;
        state = state.copyWith(
          messages: [...state.messages],
          isGenerating: false,
          errorBanner: 'Chat error: $error',
        );
      },
      onDone: () {
        if (aiMsg.isEmpty) aiMsg.text = '(empty response)';
        aiMsg.isStreaming = false;
        state = state.copyWith(
          messages: [...state.messages],
          isGenerating: false,
        );
      },
    );
  }

  void _submitRag(String text) {
    final userMsg = ChatMessage(role: MessageRole.user, text: text);
    final aiMsg = ChatMessage(
      role: MessageRole.assistant,
      text: '',
      isStreaming: true,
    );

    final msgs = [...state.messages, userMsg, aiMsg];
    state = state.copyWith(
      messages: msgs,
      isGenerating: true,
      clearError: true,
    );

    final rag = _platform.ragStream(text);

    _chatSub?.cancel();
    _chatSub = rag.tokens.listen(
      (token) {
        aiMsg.text += token;
        state = state.copyWith(messages: [...state.messages]);
      },
      onError: (error) {
        debugPrint('[ChatController] ragStream error: $error');
        aiMsg.isStreaming = false;
        state = state.copyWith(
          messages: [...state.messages],
          isGenerating: false,
          errorBanner: 'RAG error: $error',
        );
      },
      onDone: () async {
        // Get sources from the future
        try {
          final resultData = await rag.result;
          final srcList =
              (resultData['sources'] as List?)?.cast<Map<String, dynamic>>() ??
                  [];
          aiMsg.sources =
              srcList.map((m) => SourceAttribution.fromJson(m)).toList();

          // Copy images from sources into the message for inline rendering
          final allImages = <SourceImage>[];
          for (final src in aiMsg.sources) {
            allImages.addAll(src.images);
          }
          aiMsg.images = allImages;

          // Grab the text answer if no tokens were streamed
          if (aiMsg.isEmpty) {
            final answer = resultData['answer'] as String?;
            if (answer != null && answer.isNotEmpty) {
              aiMsg.text =
                  answer.startsWith('ERROR:') ? '⚠️ $answer' : answer;
            }
          }
        } catch (e) {
          debugPrint('[ChatController] RAG result parsing error: $e');
        }

        if (aiMsg.isEmpty) aiMsg.text = '(empty response)';
        aiMsg.isStreaming = false;
        state = state.copyWith(
          messages: [...state.messages],
          isGenerating: false,
        );
      },
    );
  }

  // ---- Actions ----

  Future<void> stopGeneration() async {
    await _platform.stop();
  }

  Future<void> clearMemory() async {
    try {
      await _platform.clearMemory();
      state = state.copyWith(messages: [], clearError: true);
    } catch (e) {
      debugPrint('[ChatController] clearMemory error: $e');
      state = state.copyWith(errorBanner: 'Failed to clear: $e');
    }
  }

  void dismissError() {
    state = state.copyWith(clearError: true);
  }
}

// ---- Provider ----

final chatControllerProvider =
    NotifierProvider<ChatController, ChatState>(ChatController.new);
