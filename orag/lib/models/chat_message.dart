// Represents a single chat message in the conversation.

enum MessageRole { user, assistant, system }

/// Source attribution for RAG responses.
class SourceAttribution {
  final String docName;
  final String chunkText;
  final double score;

  const SourceAttribution({
    required this.docName,
    required this.chunkText,
    required this.score,
  });

  factory SourceAttribution.fromJson(Map<String, dynamic> json) {
    return SourceAttribution(
      docName: json['doc_name'] as String? ?? '',
      chunkText: json['chunk_text'] as String? ?? '',
      score: (json['score'] as num?)?.toDouble() ?? 0.0,
    );
  }

  Map<String, dynamic> toJson() => {
    'doc_name': docName,
    'chunk_text': chunkText,
    'score': score,
  };
}

/// A parent chunk used in RAG context expansion — shown in the "Context Used" dropdown.
class ParentChunk {
  final String docName;
  final String text;
  final double score;

  const ParentChunk({
    required this.docName,
    required this.text,
    required this.score,
  });

  factory ParentChunk.fromJson(Map<String, dynamic> json) {
    return ParentChunk(
      docName: json['doc_name'] as String? ?? '',
      text: json['text'] as String? ?? '',
      score: (json['score'] as num?)?.toDouble() ?? 0.0,
    );
  }

  Map<String, dynamic> toJson() => {
    'doc_name': docName,
    'text': text,
    'score': score,
  };
}

class ChatMessage {
  final MessageRole role;
  String text;
  final DateTime timestamp;
  bool isStreaming;
  List<SourceAttribution> sources;
  String? responseStyle;

  /// Raw thinking block captured from Qwen3.
  /// Empty string if the model produced no thinking block.
  String thinkingText;

  /// Parent chunks used in RAG context expansion (Document mode only).
  List<ParentChunk> parentChunks;

  ChatMessage({
    required this.role,
    required this.text,
    DateTime? timestamp,
    this.isStreaming = false,
    List<SourceAttribution>? sources,
    this.thinkingText = '',
    List<ParentChunk>? parentChunks,
    this.responseStyle,
  }) : timestamp = timestamp ?? DateTime.now(),
       sources = sources ?? [],
       parentChunks = parentChunks ?? [];

  bool get isUser => role == MessageRole.user;
  bool get isAssistant => role == MessageRole.assistant;

  /// Whether this message has any visible content yet.
  bool get isEmpty => text.trim().isEmpty;

  /// Whether this message has source attribution data.
  bool get hasSources => sources.isNotEmpty;

  /// Whether this message has a Qwen3 thinking block to display.
  bool get hasThinking => thinkingText.isNotEmpty;

  /// Whether this message has parent chunk context to display.
  bool get hasParentChunks => parentChunks.isNotEmpty;

  Map<String, dynamic> toJson() => {
    'role': role.name,
    'text': text,
    'timestamp': timestamp.toIso8601String(),
    'sources': sources.map((s) => s.toJson()).toList(),
    'thinking_text': thinkingText,
    'parent_chunks': parentChunks.map((c) => c.toJson()).toList(),
    'response_style': responseStyle,
  };

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    final role = MessageRole.values.firstWhere(
      (r) => r.name == json['role'],
      orElse: () => MessageRole.assistant,
    );
    final srcList =
        (json['sources'] as List?)
            ?.map((s) => SourceAttribution.fromJson(s as Map<String, dynamic>))
            .toList() ??
        [];
    final chunkList =
        (json['parent_chunks'] as List?)
            ?.map((c) => ParentChunk.fromJson(c as Map<String, dynamic>))
            .toList() ??
        [];
    return ChatMessage(
      role: role,
      text: json['text'] as String? ?? '',
      timestamp:
          DateTime.tryParse(json['timestamp'] as String? ?? '') ??
          DateTime.now(),
      sources: srcList,
      thinkingText: json['thinking_text'] as String? ?? '',
      parentChunks: chunkList,
      responseStyle: json['response_style'] as String?,
    );
  }
}
