import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:file_picker/file_picker.dart';

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
  final bool isUploading;
  final String uploadStatus;
  final String? activeDocumentName;

  const ChatState({
    this.messages = const [],
    this.isGenerating = false,
    this.ragMode = false,
    this.initStatus = const InitStatus(),
    this.initDone = false,
    this.errorBanner,
    this.isUploading = false,
    this.uploadStatus = '',
    this.activeDocumentName,
  });

  ChatState copyWith({
    List<ChatMessage>? messages,
    bool? isGenerating,
    bool? ragMode,
    InitStatus? initStatus,
    bool? initDone,
    String? errorBanner,
    bool clearError = false,
    bool? isUploading,
    String? uploadStatus,
    String? activeDocumentName,
    bool clearActiveDocument = false,
  }) {
    return ChatState(
      messages: messages ?? this.messages,
      isGenerating: isGenerating ?? this.isGenerating,
      ragMode: ragMode ?? this.ragMode,
      initStatus: initStatus ?? this.initStatus,
      initDone: initDone ?? this.initDone,
      errorBanner: clearError ? null : (errorBanner ?? this.errorBanner),
      isUploading: isUploading ?? this.isUploading,
      uploadStatus: uploadStatus ?? this.uploadStatus,
      activeDocumentName: clearActiveDocument ? null : (activeDocumentName ?? this.activeDocumentName),
    );
  }
}

// ---- Controller ----

class ChatController extends Notifier<ChatState> {
  final PlatformService _platform = PlatformService();
  StreamSubscription<String>? _chatSub;
  Timer? _initTimeoutTimer;
  bool _isInitializing = false;

  // Token batching: accumulate tokens and flush every 50ms
  // to reduce rebuilds from ~300 to ~20 per response
  final StringBuffer _tokenBuffer = StringBuffer();
  Timer? _tokenFlushTimer;
  ChatMessage? _activeAiMsg;

  static const _initTimeoutDuration = Duration(minutes: 5);
  static const _tokenFlushInterval = Duration(milliseconds: 50);

  PlatformService get platform => _platform;

  @override
  ChatState build() {
    ref.onDispose(() {
      _chatSub?.cancel();
      _initTimeoutTimer?.cancel();
      _tokenFlushTimer?.cancel();
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
            // Restore persisted messages after init
            _loadPersistedMessages();
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

  // ---- Mode management ----

  void toggleRagMode() {
    if (!state.isGenerating) {
      final newMode = !state.ragMode;
      state = state.copyWith(ragMode: newMode, clearActiveDocument: !newMode);
      _addSystemMessage(
        newMode
            ? '📄 Switched to Document mode — ask questions about your uploaded documents.'
            : '🤖 Switched to AI Chat mode — general-purpose assistant.',
      );
    }
  }

  void _exitRagMode() {
    state = state.copyWith(ragMode: false, clearActiveDocument: true);
    _addSystemMessage(
      '🤖 Exited Document mode. You\'re now chatting with the AI assistant.\n'
      'Tap ➕ to add a document and return to Document mode.',
    );
  }

  void _enterRagMode({String? docName}) {
    state = state.copyWith(ragMode: true, activeDocumentName: docName);
    final label = docName ?? 'Document';
    _addSystemMessage('📄 $label type quit to go ai chat');
  }

  void _addSystemMessage(String text) {
    final sysMsg = ChatMessage(role: MessageRole.system, text: text);
    state = state.copyWith(messages: [...state.messages, sysMsg]);
    _persistMessages();
  }

  // ---- Token batching ----

  void _onToken(String token) {
    _tokenBuffer.write(token);
    _tokenFlushTimer?.cancel();
    _tokenFlushTimer = Timer(_tokenFlushInterval, _flushTokens);
  }

  void _flushTokens() {
    if (_tokenBuffer.isEmpty || _activeAiMsg == null) return;
    _activeAiMsg!.text += _tokenBuffer.toString();
    _tokenBuffer.clear();
    state = state.copyWith(messages: List.of(state.messages));
  }

  void _finishTokenStream() {
    _tokenFlushTimer?.cancel();
    // Flush any remaining buffered tokens
    if (_tokenBuffer.isNotEmpty && _activeAiMsg != null) {
      _activeAiMsg!.text += _tokenBuffer.toString();
      _tokenBuffer.clear();
    }
  }

  // ---- Unified query ----

  void submitQuery(String text) {
    if (state.isGenerating || !state.initDone) return;
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;

    // "quit" command exits RAG mode and returns to AI chat
    if (state.ragMode && trimmed.toLowerCase() == 'quit') {
      _exitRagMode();
      return;
    }

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
    _activeAiMsg = aiMsg;

    final msgs = [...state.messages, userMsg, aiMsg];
    state = state.copyWith(
      messages: msgs,
      isGenerating: true,
      clearError: true,
    );

    final chat = _platform.chatStream(text);

    _chatSub?.cancel();
    _chatSub = chat.tokens.listen(
      _onToken,
      onError: (error) {
        debugPrint('[ChatController] chatStream error: $error');
        _finishTokenStream();
        aiMsg.isStreaming = false;
        _activeAiMsg = null;
        state = state.copyWith(
          messages: List.of(state.messages),
          isGenerating: false,
          errorBanner: 'Chat error: $error',
        );
      },
      onDone: () async {
        _finishTokenStream();
        // Read thinking from the MethodChannel result JSON
        try {
          final resultData = await chat.result;
          final thinking = resultData['thinking'] as String? ?? '';
          if (thinking.isNotEmpty) {
            aiMsg.thinkingText = thinking;
          }
          // Use answer from JSON only if no tokens were streamed
          if (aiMsg.isEmpty) {
            final answer = resultData['answer'] as String? ?? '';
            if (answer.isNotEmpty) {
              aiMsg.text = answer.startsWith('ERROR:') ? '⚠️ $answer' : answer;
            }
          }
        } catch (e) {
          debugPrint('[ChatController] chatStream result parse error: $e');
        }
        if (aiMsg.isEmpty) aiMsg.text = '(empty response)';
        aiMsg.isStreaming = false;
        _activeAiMsg = null;
        state = state.copyWith(
          messages: List.of(state.messages),
          isGenerating: false,
        );
        _persistMessages();
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
    _activeAiMsg = aiMsg;

    final msgs = [...state.messages, userMsg, aiMsg];
    state = state.copyWith(
      messages: msgs,
      isGenerating: true,
      clearError: true,
    );

    final rag = _platform.ragStream(text);

    _chatSub?.cancel();
    _chatSub = rag.tokens.listen(
      _onToken,
      onError: (error) {
        debugPrint('[ChatController] ragStream error: $error');
        _finishTokenStream();
        aiMsg.isStreaming = false;
        _activeAiMsg = null;
        state = state.copyWith(
          messages: List.of(state.messages),
          isGenerating: false,
          errorBanner: 'RAG error: $error',
        );
      },
      onDone: () async {
        _finishTokenStream();
        // Get sources, thinking, and parent chunks from the future
        try {
          final resultData = await rag.result;
          final srcList =
              (resultData['sources'] as List?)?.cast<Map<String, dynamic>>() ??
                  [];
          aiMsg.sources =
              srcList.map((m) => SourceAttribution.fromJson(m)).toList();

          // Parse thinking block
          final thinking = resultData['thinking'] as String? ?? '';
          if (thinking.isNotEmpty) {
            aiMsg.thinkingText = thinking;
          }

          // Parse parent chunks used in RAG context
          final chunkList =
              (resultData['parent_chunks'] as List?)?.cast<Map<String, dynamic>>() ??
                  [];
          aiMsg.parentChunks =
              chunkList.map((m) => ParentChunk.fromJson(m)).toList();

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
        _activeAiMsg = null;
        state = state.copyWith(
          messages: List.of(state.messages),
          isGenerating: false,
        );
        _persistMessages();
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
      _persistMessages();
    } catch (e) {
      debugPrint('[ChatController] clearMemory error: $e');
      state = state.copyWith(errorBanner: 'Failed to clear: $e');
    }
  }

  Future<void> pickAndUploadFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf', 'txt'],
      allowMultiple: true,
    );
    if (result == null || result.files.isEmpty) return;

    final fileNames = result.files.map((f) => f.name).join(', ');
    final tempMsg = ChatMessage(role: MessageRole.system, text: 'Uploading $fileNames…');

    state = state.copyWith(
      isUploading: true, 
      uploadStatus: 'Reading files…',
      messages: [...state.messages, tempMsg],
    );

    final stopwatch = Stopwatch()..start();
    final statusTimer = Stream.periodic(
      const Duration(seconds: 1),
      (i) => i,
    ).listen((_) {
      tempMsg.text = 'Processing $fileNames… ${stopwatch.elapsed.inSeconds}s';
      state = state.copyWith(
        uploadStatus: 'Processing… ${stopwatch.elapsed.inSeconds}s',
        messages: List.of(state.messages),
      );
    });

    bool allSuccess = true;
    String lastMessage = '';

    for (var file in result.files) {
      if (file.path == null) continue;
      final response = await _platform.uploadDocument(file.path!);
      if (response['success'] != true) {
        allSuccess = false;
        lastMessage = response['message'] as String? ?? 'Failed to upload ${file.name}';
        break; // Stop on first error
      }
    }

    statusTimer.cancel();
    stopwatch.stop();

    final finalMessages = state.messages.where((m) => m != tempMsg).toList();

    state = state.copyWith(
      isUploading: false,
      uploadStatus: '',
      errorBanner: allSuccess ? null : 'Upload failed: $lastMessage',
      clearError: allSuccess,
      messages: finalMessages,
    );

    // Auto-switch to RAG mode with a system message
    if (allSuccess) {
      final docName = result.files.length == 1 ? result.files.first.name : '${result.files.length} documents';
      _enterRagMode(docName: docName);
    }
  }

  void dismissError() {
    state = state.copyWith(clearError: true);
  }

  // ---- Persistence (Fix #22) ----

  Future<File> get _persistFile async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/orag_messages.json');
  }

  Future<void> _persistMessages() async {
    try {
      final file = await _persistFile;
      final nonStreaming = state.messages
          .where((m) => !m.isStreaming)
          .map((m) => m.toJson())
          .toList();
      // Keep only the last 100 messages to limit file size
      final toSave = nonStreaming.length > 100
          ? nonStreaming.sublist(nonStreaming.length - 100)
          : nonStreaming;
      await file.writeAsString(jsonEncode(toSave));
    } catch (e) {
      debugPrint('[ChatController] persist error: $e');
    }
  }

  Future<void> _loadPersistedMessages() async {
    try {
      final file = await _persistFile;
      if (!await file.exists()) return;
      final raw = await file.readAsString();
      final list = jsonDecode(raw) as List;
      final messages = list
          .map((j) => ChatMessage.fromJson(j as Map<String, dynamic>))
          .toList();
      if (messages.isNotEmpty) {
        state = state.copyWith(messages: messages);
      }
    } catch (e) {
      debugPrint('[ChatController] load persisted messages error: $e');
    }
  }
}

// ---- Provider ----

final chatControllerProvider =
    NotifierProvider<ChatController, ChatState>(ChatController.new);
