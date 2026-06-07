import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orag/controllers/theme_controller.dart';
import 'package:orag/screens/settings_screen.dart';
import 'package:orag/services/platform_service.dart';
import 'package:orag/theme/app_theme.dart';
import 'package:orag/widgets/chat_empty_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

Widget _testApp(Widget child) {
  return ProviderScope(
    child: MaterialApp(
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      home: child,
    ),
  );
}

class _FakePlatformService extends PlatformService {
  @override
  Future<Map<String, dynamic>> getEngineHealth() async {
    return {
      'qwen_ready': true,
      'nomic_ready': true,
      'doc_count': 2,
      'chunk_count': 12,
      'backend': 'Test backend',
    };
  }

  @override
  Future<Map<String, dynamic>> getResourceUsage() async {
    return {'profile_name': 'Test profile'};
  }

  @override
  Future<bool> clearDocuments() async => true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('AppTheme exposes custom colors for both modes', () {
    expect(AppTheme.light.extension<OragColors>(), isNotNull);
    expect(AppTheme.dark.extension<OragColors>(), isNotNull);
  });

  test('theme controller defaults to system mode', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(container.read(themeControllerProvider), ThemeMode.system);
  });

  testWidgets('settings renders appearance control', (tester) async {
    await tester.pumpWidget(
      _testApp(
        SettingsScreen(platform: _FakePlatformService(), onClearChat: () {}),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Appearance'), findsOneWidget);
    expect(find.text('System'), findsOneWidget);
    expect(find.text('Light'), findsOneWidget);
    expect(find.text('Dark'), findsOneWidget);
  });

  testWidgets('empty state renders redesigned actions and keeps prompts tappable', (
    tester,
  ) async {
    String? prompt;
    var openedDocs = false;

    await tester.pumpWidget(
      _testApp(
        ChatEmptyState(
          ragMode: false,
          onPromptTapped: (value) => prompt = value,
          onOpenDocuments: () => openedDocs = true,
        ),
      ),
    );
    await tester.pump();

    expect(find.byKey(const ValueKey('empty_state_primary_action')), findsOneWidget);
    expect(find.byKey(const ValueKey('empty_state_documents_action')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('empty_state_prompt_chip_Explain Physics to me')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('empty_state_prompt_chip_Explain Physics to me')));
    expect(prompt, 'Explain Physics to me');

    await tester.tap(find.byKey(const ValueKey('empty_state_documents_action')));
    expect(openedDocs, isTrue);
  });
}
