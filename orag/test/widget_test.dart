// Smoke test — verifies OragApp mounts without throwing.
// Replace / extend with feature-specific widget tests as the app grows.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:orag/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    // Prevent GoogleFonts from attempting network/asset fetches in tests
    GoogleFonts.config.allowRuntimeFetching = false;

    // Mock path_provider so getExternalStorageDirectory() doesn't crash
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (MethodCall methodCall) async {
        if (methodCall.method == 'getExternalStorageDirectory') {
          return '/tmp/mock_external';
        }
        if (methodCall.method == 'getApplicationDocumentsDirectory') {
          return '/tmp/mock_documents';
        }
        if (methodCall.method == 'getTemporaryDirectory') {
          return '/tmp/mock_temp';
        }
        return null;
      },
    );

    // Mock path_provider_android (used on newer Flutter versions)
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider_android'),
      (MethodCall methodCall) async {
        if (methodCall.method == 'getExternalStorageDirectory') {
          return '/tmp/mock_external';
        }
        if (methodCall.method == 'getApplicationDocumentsDirectory') {
          return '/tmp/mock_documents';
        }
        if (methodCall.method == 'getTemporaryDirectory') {
          return '/tmp/mock_temp';
        }
        if (methodCall.method == 'getExternalStorageDirectories') {
          return <String>['/tmp/mock_external'];
        }
        return null;
      },
    );
  });

  testWidgets('OragApp renders without crashing', (WidgetTester tester) async {
    // Silence image-loading and font errors — assets aren't bundled in tests
    final originalOnError = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails details) {
      final message = details.exceptionAsString();
      if (message.contains('Unable to load asset') ||
          message.contains('Could not find a set of fonts') ||
          message.contains('codec') ||
          message.contains('MissingPluginException') ||
          message.contains('ImageCodecException')) {
        return; // swallow expected test-env failures
      }
      if (originalOnError != null) originalOnError(details);
    };

    await tester.pumpWidget(const OragApp());
    // Pump one frame to let the widget tree settle (don't advance timers
    // far enough to trigger the splash→chat navigation at 2800 ms).
    await tester.pump(const Duration(milliseconds: 100));

    // Restore error handler
    FlutterError.onError = originalOnError;

    // If we get here without an unhandled exception, the app boots fine.
    expect(find.byType(MaterialApp), findsOneWidget);
  });
}
