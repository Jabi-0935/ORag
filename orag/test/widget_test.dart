// Minimal smoke tests — verifies key classes can be instantiated.
// Full widget tests that depend on platform channels (path_provider,
// method channels, etc.) should be run as integration tests on a real
// device / emulator, not in the headless CI unit-test runner.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orag/theme/app_theme.dart';

void main() {
  test('AppTheme.dark returns a valid ThemeData', () {
    final theme = AppTheme.dark;
    expect(theme, isA<ThemeData>());
    expect(theme.scaffoldBackgroundColor, equals(AppColors.background));
  });

  test('AppColors constants are not null', () {
    expect(AppColors.background, isNotNull);
    expect(AppColors.primary, isNotNull);
    expect(AppColors.surface, isNotNull);
    expect(AppColors.error, isNotNull);
    expect(AppColors.textPrimary, isNotNull);
  });
}
