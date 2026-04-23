// Represents a single chat message in the conversation.

enum MessageRole { user, assistant, system }

/// A single image extracted from a document page.
class SourceImage {
  final String path;
  final int page;
  final int width;
  final int height;

  const SourceImage({
    required this.path,
    this.page = 0,
    this.width = 0,
    this.height = 0,
  });

  factory SourceImage.fromJson(Map<String, dynamic> json) {
    return SourceImage(
      path: json['path'] as String? ?? '',
      page: (json['page'] as num?)?.toInt() ?? 0,
      width: (json['width'] as num?)?.toInt() ?? 0,
      height: (json['height'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Source attribution for RAG responses.
class SourceAttribution {
  final String docName;
  final String chunkText;
  final double score;
  final List<SourceImage> images;

  const SourceAttribution({
    required this.docName,
    required this.chunkText,
    required this.score,
    this.images = const [],
  });

  factory SourceAttribution.fromJson(Map<String, dynamic> json) {
    final rawImages = json['images'] as List<dynamic>? ?? [];
    return SourceAttribution(
      docName: json['doc_name'] as String? ?? '',
      chunkText: json['chunk_text'] as String? ?? '',
      score: (json['score'] as num?)?.toDouble() ?? 0.0,
      images: rawImages
          .map((img) => SourceImage.fromJson(img as Map<String, dynamic>))
          .toList(),
    );
  }

  bool get hasImages => images.isNotEmpty;

  Map<String, dynamic> toJson() => {
    'doc_name': docName,
    'chunk_text': chunkText,
    'score': score,
    'images': images.map((i) => {'path': i.path, 'page': i.page, 'width': i.width, 'height': i.height}).toList(),
  };
}

class ChatMessage {
  final MessageRole role;
  String text;
  final DateTime timestamp;
  bool isStreaming;
  List<SourceAttribution> sources;

  /// Images extracted from RAG source documents for inline rendering.
  List<SourceImage> images;

  ChatMessage({
    required this.role,
    required this.text,
    DateTime? timestamp,
    this.isStreaming = false,
    List<SourceAttribution>? sources,
    List<SourceImage>? images,
  })  : timestamp = timestamp ?? DateTime.now(),
        sources = sources ?? [],
        images = images ?? [];

  bool get isUser => role == MessageRole.user;
  bool get isAssistant => role == MessageRole.assistant;

  /// Whether this message has any visible content yet.
  bool get isEmpty => text.trim().isEmpty;

  /// Whether this message has source attribution data.
  bool get hasSources => sources.isNotEmpty;

  /// Whether this message has inline images to render.
  bool get hasImages => images.isNotEmpty;

  Map<String, dynamic> toJson() => {
    'role': role.name,
    'text': text,
    'timestamp': timestamp.toIso8601String(),
    'sources': sources.map((s) => s.toJson()).toList(),
  };

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    final role = MessageRole.values.firstWhere(
      (r) => r.name == json['role'],
      orElse: () => MessageRole.assistant,
    );
    final srcList = (json['sources'] as List?)?.map(
      (s) => SourceAttribution.fromJson(s as Map<String, dynamic>),
    ).toList() ?? [];
    return ChatMessage(
      role: role,
      text: json['text'] as String? ?? '',
      timestamp: DateTime.tryParse(json['timestamp'] as String? ?? '') ?? DateTime.now(),
      sources: srcList,
    );
  }
}
