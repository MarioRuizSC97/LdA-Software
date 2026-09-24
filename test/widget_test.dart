import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/main.dart';

void main() {
  testWidgets('inventory placeholder renders accessibly', (
    WidgetTester tester,
  ) async {
    final SemanticsHandle semantics = tester.ensureSemantics();

    try {
      await tester.pumpWidget(const LdaInventoryApp());

      final MaterialApp app = tester.widget(find.byType(MaterialApp));
      expect(app.title, 'LDA Inventory');
      expect(find.text('Inventory foundation ready'), findsOneWidget);
      expect(
        find.text('Inventory features are not configured yet.'),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel('Inventory foundation ready'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    } finally {
      semantics.dispose();
    }
  });
}
