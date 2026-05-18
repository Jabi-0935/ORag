import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import '../theme/app_theme.dart';

/// Chat text input bar with voice input support.
///  - Disabled (during init): grayed out, "AI is loading…"
///  - Ready: active input with mic + send buttons
///  - Generating: disabled, shows animated stop button
class ChatInputBar extends StatefulWidget {
  final TextEditingController controller;
  final bool enabled;
  final bool isGenerating;
  final bool ragMode;
  final String? activeDocumentName;
  final VoidCallback onSend;
  final VoidCallback onStop;
  final VoidCallback onAddFile;
  final bool isUploading;
  final String uploadStatus;

  const ChatInputBar({
    super.key,
    required this.controller,
    required this.enabled,
    required this.isGenerating,
    required this.ragMode,
    this.activeDocumentName,
    required this.onSend,
    required this.onStop,
    required this.onAddFile,
    required this.isUploading,
    required this.uploadStatus,
  });

  @override
  State<ChatInputBar> createState() => _ChatInputBarState();
}

class _ChatInputBarState extends State<ChatInputBar> {
  final stt.SpeechToText _speech = stt.SpeechToText();
  bool _isListening = false;
  bool _speechAvailable = false;

  @override
  void initState() {
    super.initState();
    _initSpeech();
  }

  Future<void> _initSpeech() async {
    try {
      _speechAvailable = await _speech.initialize(
        onStatus: (status) {
          if (status == 'done' || status == 'notListening') {
            if (mounted) setState(() => _isListening = false);
          }
        },
        onError: (error) {
          if (mounted) setState(() => _isListening = false);
        },
      );
    } catch (e) {
      _speechAvailable = false;
    }
    if (mounted) setState(() {});
  }

  Future<void> _toggleListening() async {
    if (_isListening) {
      await _speech.stop();
      setState(() => _isListening = false);
    } else {
      if (!_speechAvailable) {
        await _initSpeech();
        if (!_speechAvailable) return;
      }
      setState(() => _isListening = true);
      await _speech.listen(
        onResult: (result) {
          widget.controller.text = result.recognizedWords;
          widget.controller.selection = TextSelection.fromPosition(
            TextPosition(offset: widget.controller.text.length),
          );
        },
        listenFor: const Duration(seconds: 30),
        pauseFor: const Duration(seconds: 3),
        partialResults: true,
        localeId: 'en_US',
      );
    }
  }

  @override
  void dispose() {
    _speech.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(
          top: BorderSide(color: AppColors.divider, width: 1),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            if (!widget.isGenerating && widget.enabled && !widget.isUploading)
              IconButton(
                icon: const Icon(Icons.add_circle_outline_rounded, size: 28),
                color: AppColors.textSecondary,
                onPressed: widget.onAddFile,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
              ),
            if (!widget.isGenerating && widget.enabled && !widget.isUploading)
              const SizedBox(width: 12),
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: _isListening
                      ? AppColors.primary.withValues(alpha: 0.05)
                      : AppColors.inputFill,
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(
                    color: _isListening
                        ? AppColors.primary.withValues(alpha: 0.4)
                        : AppColors.inputBorder,
                    width: 1,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.2),
                      blurRadius: 10,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: widget.isUploading
                    ? Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 18, vertical: 12),
                        child: Row(
                          children: [
                            const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: AppColors.primary,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                widget.uploadStatus.isNotEmpty
                                    ? widget.uploadStatus
                                    : 'Uploading...',
                                style: const TextStyle(
                                  color: AppColors.textDim,
                                  fontSize: 15,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      )
                    : KeyboardListener(
                        focusNode: FocusNode(),
                        onKeyEvent: (event) {
                          if (event is KeyDownEvent &&
                              event.logicalKey == LogicalKeyboardKey.enter &&
                              !HardwareKeyboard.instance.isShiftPressed &&
                              widget.enabled &&
                              !widget.isGenerating) {
                            widget.onSend();
                          }
                        },
                        child: TextField(
                          controller: widget.controller,
                          enabled: widget.enabled && !widget.isGenerating,
                          maxLines: 4,
                          minLines: 1,
                          style: const TextStyle(
                            color: AppColors.textPrimary,
                            fontSize: 15,
                          ),
                          decoration: InputDecoration(
                            hintText: _hintText,
                            hintStyle: const TextStyle(
                              color: AppColors.textDim,
                              fontSize: 15,
                            ),
                            border: InputBorder.none,
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 18,
                              vertical: 12,
                            ),
                          ),
                          textInputAction: TextInputAction.send,
                          onSubmitted:
                              widget.enabled && !widget.isGenerating ? (_) => widget.onSend() : null,
                        ),
                      ),
              ),
            ),
            const SizedBox(width: 8),
            // Microphone button
            if (!widget.isGenerating && widget.enabled && !widget.isUploading)
              _MicButton(
                isListening: _isListening,
                onTap: _toggleListening,
              ),
            if (!widget.isGenerating && widget.enabled && !widget.isUploading)
              const SizedBox(width: 4),
            _actionButton(),
          ],
        ),
      ),
    );
  }

  String get _hintText {
    if (!widget.enabled) return 'AI is loading…';
    if (widget.isGenerating) return 'Generating…';
    if (_isListening) return 'Listening…';
    if (widget.ragMode) {
      return widget.activeDocumentName != null
          ? 'Ask about ${widget.activeDocumentName}…'
          : 'Ask a question about your document…';
    }
    return 'Ask me anything…';
  }

  Widget _actionButton() {
    if (widget.isGenerating) {
      return _StopButton(onTap: widget.onStop);
    }
    return _SendButton(
      onTap: widget.enabled ? widget.onSend : null,
    );
  }
}

class _MicButton extends StatelessWidget {
  final bool isListening;
  final VoidCallback onTap;
  const _MicButton({required this.isListening, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          color: isListening
              ? AppColors.error.withValues(alpha: 0.15)
              : AppColors.secondary.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(19),
        ),
        child: Icon(
          isListening ? Icons.mic_off_rounded : Icons.mic_rounded,
          color: isListening ? AppColors.error : AppColors.secondary,
          size: 20,
        ),
      ),
    );
  }
}

class _SendButton extends StatelessWidget {
  final VoidCallback? onTap;
  const _SendButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final active = onTap != null;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color:
              active ? AppColors.primary : AppColors.primary.withValues(alpha: 0.2),
          borderRadius: BorderRadius.circular(22),
        ),
        child: Icon(
          Icons.arrow_upward_rounded,
          color:
              active ? AppColors.background : AppColors.textDim,
          size: 22,
        ),
      ),
    );
  }
}

class _StopButton extends StatefulWidget {
  final VoidCallback onTap;
  const _StopButton({required this.onTap});

  @override
  State<_StopButton> createState() => _StopButtonState();
}

class _StopButtonState extends State<_StopButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      child: AnimatedBuilder(
        animation: _pulse,
        builder: (context, child) {
          return Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: AppColors.error
                  .withValues(alpha: 0.8 + 0.2 * _pulse.value),
              borderRadius: BorderRadius.circular(22),
              boxShadow: [
                BoxShadow(
                  color: AppColors.error.withValues(alpha: 0.3 * _pulse.value),
                  blurRadius: 12,
                  spreadRadius: 2,
                ),
              ],
            ),
            child: const Icon(
              Icons.stop_rounded,
              color: Colors.white,
              size: 22,
            ),
          );
        },
      ),
    );
  }
}
