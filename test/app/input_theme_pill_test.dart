import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/app/inventory_theme.dart';

void main() {
  for (final dark in <bool>[false, true]) {
    final name = dark ? 'dark' : 'light';
    final theme = dark ? buildDarkInventoryTheme() : buildInventoryTheme();

    testWidgets('$name plain input uses a compact unfilled pill outline', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: const Scaffold(body: TextField()),
        ),
      );
      final decoration = tester
          .widget<InputDecorator>(find.byType(InputDecorator))
          .decoration;
      expect(decoration.border, isA<OutlineInputBorder>());
      final border = decoration.border! as OutlineInputBorder;
      expect(border.borderRadius.topLeft.x, greaterThanOrEqualTo(24));
      expect(border.borderRadius, BorderRadius.circular(999));
      expect(decoration.filled, isFalse);
      expect(decoration.contentPadding!.vertical, lessThanOrEqualTo(24));

      await tester.tap(find.byType(TextField));
      await tester.pumpAndSettle();
      expect(
        tester.getSize(find.byType(InputDecorator)).height,
        lessThanOrEqualTo(56),
      );
    });

    testWidgets('$name explicit quantity-style decoration still wins', (
      tester,
    ) async {
      const border = OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(8)),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: const Scaffold(
            body: TextField(
              decoration: InputDecoration(
                border: border,
                isDense: true,
                contentPadding: EdgeInsets.all(4),
              ),
            ),
          ),
        ),
      );
      final decoration = tester
          .widget<InputDecorator>(find.byType(InputDecorator))
          .decoration;
      expect(decoration.border, border);
      expect(decoration.isDense, isTrue);
      expect(decoration.contentPadding, const EdgeInsets.all(4));
    });
  }
}
