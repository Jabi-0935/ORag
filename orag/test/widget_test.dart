// Smoke test — verifies OragApp mounts without throwing.
// Replace / extend with feature-specific widget tests as the app grows.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:orag/main.dart';

void main() {
  setUpAll(() {
    // Prevent GoogleFonts from attempting network/asset fetches in tests
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  testWidgets('OragApp renders without crashing', (WidgetTester tester) async {
    // Silence image-loading errors (assets aren't bundled in test runner)
    final originalOnError = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails details) {
      final message = details.exceptionAsString();
      // Ignore asset/image/font load failures — expected in unit tests
      if (message.contains('Unable to load asset') ||
          message.contains('Could not find a set of fonts') ||
          message.contains('codec')) {
        return;
      }
      // Re-throw anything else
      if (originalOnError != null) originalOnError(details);
    };

    await tester.pumpWidget(const OragApp());
    await tester.pump();

    // Restore error handler
    FlutterError.onError = originalOnError;

    expect(find.byType(OragApp), findsOneWidget);
  });
}
