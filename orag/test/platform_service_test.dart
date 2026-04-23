import 'package:flutter_test/flutter_test.dart';
import 'package:orag/models/chat_message.dart';
import 'package:orag/services/platform_service.dart';

void main() {
  // ---- InitStatus ----

  group('InitStatus', () {
    test('default values are idle/zero/empty', () {
      const s = InitStatus();
      expect(s.state, InitState.idle);
      expect(s.progress, 0.0);
      expect(s.message, '');
      expect(s.isReady, false);
      expect(s.isError, false);
    });

    test('isReady returns true for ready state', () {
      const s = InitStatus(state: InitState.ready, progress: 1.0, message: 'Done');
      expect(s.isReady, true);
      expect(s.isError, false);
    });

    test('isError returns true for error state', () {
      const s = InitStatus(state: InitState.error, progress: 1.0, message: 'Failed');
      expect(s.isError, true);
      expect(s.isReady, false);
    });
  });



  // ---- SourceAttribution ----

  group('SourceAttribution', () {
    test('fromJson parses complete data without images', () {
      final json = {
        'doc_name': 'test.pdf',
        'chunk_text': 'Some relevant passage...',
        'score': 0.85,
      };
      final src = SourceAttribution.fromJson(json);
      expect(src.docName, 'test.pdf');
      expect(src.chunkText, 'Some relevant passage...');
      expect(src.score, 0.85);
    });

    test('fromJson handles missing values gracefully', () {
      final src = SourceAttribution.fromJson({
        'doc_name': 'file.txt',
        'chunk_text': 'text',
        'score': 0.5,
      });
      expect(src.docName, 'file.txt');
    });

    test('fromJson handles empty map', () {
      final src = SourceAttribution.fromJson({});
      expect(src.docName, '');
      expect(src.chunkText, '');
      expect(src.score, 0.0);
    });
  });

  // ---- ChatMessage ----

  group('ChatMessage', () {
    test('user message role is detected', () {
      final msg = ChatMessage(role: MessageRole.user, text: 'Hello');
      expect(msg.isUser, true);
      expect(msg.isAssistant, false);
    });

    test('assistant message role is detected', () {
      final msg = ChatMessage(role: MessageRole.assistant, text: 'Hi');
      expect(msg.isAssistant, true);
      expect(msg.isUser, false);
    });

    test('isEmpty returns true for whitespace-only text', () {
      final msg = ChatMessage(role: MessageRole.assistant, text: '   ');
      expect(msg.isEmpty, true);
    });

    test('isEmpty returns false for text with content', () {
      final msg = ChatMessage(role: MessageRole.assistant, text: 'answer');
      expect(msg.isEmpty, false);
    });

    test('hasSources returns false when no sources', () {
      final msg = ChatMessage(role: MessageRole.assistant, text: 'text');
      expect(msg.hasSources, false);
    });

    test('hasSources returns true when sources present', () {
      final msg = ChatMessage(
        role: MessageRole.assistant,
        text: 'text',
        sources: [
          const SourceAttribution(docName: 'a', chunkText: 'b', score: 0.9),
        ],
      );
      expect(msg.hasSources, true);
    });

    test('default timestamp is approximately now', () {
      final before = DateTime.now();
      final msg = ChatMessage(role: MessageRole.user, text: 'test');
      final after = DateTime.now();
      expect(msg.timestamp.isAfter(before.subtract(const Duration(seconds: 1))), true);
      expect(msg.timestamp.isBefore(after.add(const Duration(seconds: 1))), true);
    });

    test('streaming flag can be toggled', () {
      final msg = ChatMessage(
        role: MessageRole.assistant,
        text: '',
        isStreaming: true,
      );
      expect(msg.isStreaming, true);
      msg.isStreaming = false;
      expect(msg.isStreaming, false);
    });
  });
}
