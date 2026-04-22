// Smoke test — verifies OragApp mounts without throwing.
// Replace / extend with feature-specific widget tests as the app grows.

import 'package:flutter_test/flutter_test.dart';
import 'package:orag/main.dart';

void main() {
  testWidgets('OragApp renders without crashing', (WidgetTester tester) async {
    await tester.pumpWidget(const OragApp());
    // If the app builds and paints one frame without an exception, we pass.
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
