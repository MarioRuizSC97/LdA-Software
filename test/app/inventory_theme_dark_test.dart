import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/app/inventory_theme.dart';

void main() {
  test('light surfaces remain unchanged', () {
    final theme = buildInventoryTheme();
    expect(theme.colorScheme.brightness, Brightness.light);
    expect(theme.scaffoldBackgroundColor, const Color(0xFFF6F7F9));
    expect(theme.cardTheme.color, Colors.white);
    expect(theme.cardTheme.elevation, 0);
    final shape = theme.cardTheme.shape! as RoundedRectangleBorder;
    expect(shape.side.color, const Color(0xFFE8EBEF));
    expect(shape.borderRadius, BorderRadius.circular(12));
  });

  test('dark surfaces and controls use the dark color scheme', () {
    final theme = buildDarkInventoryTheme();
    final scheme = theme.colorScheme;
    expect(theme.brightness, Brightness.dark);
    expect(scheme.brightness, Brightness.dark);
    expect(theme.scaffoldBackgroundColor, scheme.surface);
    expect(theme.cardTheme.color, scheme.surfaceContainerLow);
    expect(theme.cardTheme.color, isNot(Colors.white));
    expect(theme.inputDecorationTheme.fillColor, scheme.surfaceContainerHighest);
    expect(theme.cardTheme.elevation, 0);
    final shape = theme.cardTheme.shape! as RoundedRectangleBorder;
    expect(shape.side.color, scheme.outlineVariant);
    expect(shape.borderRadius, BorderRadius.circular(12));
  });
}
