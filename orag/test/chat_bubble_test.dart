import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orag/models/chat_message.dart';
import 'package:orag/widgets/chat_bubble.dart';

/// Wraps a widget in a MaterialApp for testing.
Widget _testApp(Widget child) {
  return MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(child: child),
    ),
  );
}

void main() {
  group('ChatBubble', () {
    testWidgets('renders user message text', (tester) async {
      final msg = ChatMessage(role: MessageRole.user, text: 'Hello AI!');
      await tester.pumpWidget(_testApp(ChatBubble(message: msg)));
      await tester.pumpAndSettle();

      expect(find.text('Hello AI!'), findsOneWidget);
    });

    testWidgets('renders assistant message text', (tester) async {
      final msg = ChatMessage(role: MessageRole.assistant, text: 'Hi there!');
      await tester.pumpWidget(_testApp(ChatBubble(message: msg)));
      await tester.pumpAndSettle();

      expect(find.text('Hi there!'), findsOneWidget);
    });

    testWidgets('shows user avatar icon', (tester) async {
      final msg = ChatMessage(role: MessageRole.user, text: 'test');
      await tester.pumpWidget(_testApp(ChatBubble(message: msg)));
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.person_rounded), findsOneWidget);
    });

    testWidgets('shows AI avatar image', (tester) async {
      final msg = ChatMessage(role: MessageRole.assistant, text: 'test');
      await tester.pumpWidget(_testApp(ChatBubble(message: msg)));
      await tester.pumpAndSettle();

      expect(find.byType(Image), findsOneWidget);
    });

    testWidgets('shows TTS button for non-streaming AI messages', (tester) async {
      final msg = ChatMessage(
        role: MessageRole.assistant,
        text: 'This is a response',
        isStreaming: false,
      );
      await tester.pumpWidget(_testApp(ChatBubble(message: msg)));
      await tester.pumpAndSettle();

      expect(find.text('Listen'), findsOneWidget);
    });

    testWidgets('hides TTS button during streaming', (tester) async {
      final msg = ChatMessage(
        role: MessageRole.assistant,
        text: 'partial...',
        isStreaming: true,
      );
      await tester.pumpWidget(_testApp(ChatBubble(message: msg)));
      await tester.pumpAndSettle();

      expect(find.text('Listen'), findsNothing);
    });

    testWidgets('hides TTS button for user messages', (tester) async {
      final msg = ChatMessage(role: MessageRole.user, text: 'question');
      await tester.pumpWidget(_testApp(ChatBubble(message: msg)));
      await tester.pumpAndSettle();

      expect(find.text('Listen'), findsNothing);
    });

  });
}
