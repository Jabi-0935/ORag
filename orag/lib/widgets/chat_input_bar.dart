import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

import '../theme/app_theme.dart';

/// Chat text input bar with voice input support.
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
      return;
    }

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
      listenOptions: stt.SpeechListenOptions(
        listenFor: const Duration(seconds: 30),
        pauseFor: const Duration(seconds: 3),
        partialResults: true,
        localeId: 'en_US',
      ),
    );
  }

  @override
  void dispose() {
    _speech.stop();
    super.dispose();
  }

  bool get _showActions =>
      !widget.isGenerating && widget.enabled && !widget.isUploading;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final scheme = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      color: Colors.transparent,
      child: SafeArea(
        top: false,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(24),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
            child: Container(
              decoration: BoxDecoration(
                color: _isListening
                    ? scheme.primary.withValues(alpha: 0.08)
                    : colors.inputFill,
                borderRadius: BorderRadius.circular(24),
                border: Border.all(
                  color: _isListening
                      ? scheme.primary.withValues(alpha: 0.42)
                      : colors.inputBorder,
                  width: 1,
                ),
                boxShadow: [
                  BoxShadow(
                    color: colors.shadow.withValues(alpha: 0.22),
                    blurRadius: 18,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  if (_showActions)
                    Padding(
                      padding: const EdgeInsets.only(left: 6),
                      child: _buildSmallIconBtn(
                        icon: Icons.add_rounded,
                        color: colors.textSecondary,
                        onPressed: widget.onAddFile,
                      ),
                    ),
                  Expanded(
                    child: KeyboardListener(
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
                        style: TextStyle(
                          color: colors.textPrimary,
                          fontSize: 15,
                        ),
                        decoration: InputDecoration(
                          hintText: _hintText,
                          hintStyle: TextStyle(
                            color: colors.textDim,
                            fontSize: 15,
                          ),
                          border: InputBorder.none,
                          contentPadding: EdgeInsets.only(
                            left: _showActions ? 4 : 18,
                            right: 4,
                            top: 10,
                            bottom: 10,
                          ),
                        ),
                        textInputAction: TextInputAction.send,
                        onSubmitted: widget.enabled && !widget.isGenerating
                            ? (_) => widget.onSend()
                            : null,
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(right: 5),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (_showActions) ...[
                          _MicButton(
                            isListening: _isListening,
                            onTap: _toggleListening,
                          ),
                          const SizedBox(width: 4),
                        ],
                        _actionButton(),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSmallIconBtn({
    required IconData icon,
    required Color color,
    required VoidCallback onPressed,
  }) {
    final colors = context.colors;
    return GestureDetector(
      onTap: onPressed,
      child: Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          color: colors.surfaceLight.withValues(alpha: 0.78),
          borderRadius: BorderRadius.circular(17),
        ),
        child: Icon(icon, size: 20, color: color),
      ),
    );
  }

  String get _hintText {
    if (!widget.enabled) return 'AI is loading...';
    if (widget.isGenerating) return 'Generating...';
    if (_isListening) return 'Listening...';
    if (widget.ragMode) {
      return widget.activeDocumentName != null
          ? 'Ask about ${widget.activeDocumentName}...'
          : 'Ask a question about your document...';
    }
    return 'Ask me anything...';
  }

  Widget _actionButton() {
    if (widget.isGenerating) {
      return _StopButton(onTap: widget.onStop);
    }
    return _SendButton(onTap: widget.enabled ? widget.onSend : null);
  }
}

class _MicButton extends StatelessWidget {
  final bool isListening;
  final VoidCallback onTap;

  const _MicButton({required this.isListening, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final scheme = Theme.of(context).colorScheme;

    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          color: isListening
              ? colors.error.withValues(alpha: 0.15)
              : scheme.secondary.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(17),
        ),
        child: Icon(
          isListening ? Icons.mic_off_rounded : Icons.mic_rounded,
          color: isListening ? colors.error : scheme.secondary,
          size: 18,
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
    final colors = context.colors;
    final scheme = Theme.of(context).colorScheme;
    final active = onTap != null;

    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: active
              ? scheme.primary
              : scheme.primary.withValues(alpha: 0.18),
          borderRadius: BorderRadius.circular(18),
        ),
        child: Icon(
          Icons.arrow_upward_rounded,
          color: active ? scheme.onPrimary : colors.textDim,
          size: 20,
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
    final colors = context.colors;

    return GestureDetector(
      onTap: widget.onTap,
      child: AnimatedBuilder(
        animation: _pulse,
        builder: (context, child) {
          return Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: colors.error.withValues(alpha: 0.8 + 0.2 * _pulse.value),
              borderRadius: BorderRadius.circular(18),
              boxShadow: [
                BoxShadow(
                  color: colors.error.withValues(alpha: 0.3 * _pulse.value),
                  blurRadius: 12,
                  spreadRadius: 2,
                ),
              ],
            ),
            child: const Icon(
              Icons.stop_rounded,
              color: Colors.white,
              size: 20,
            ),
          );
        },
      ),
    );
  }
}
