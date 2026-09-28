import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/catalog/catalog_product.dart';
import 'package:lda_inventory/catalog/catalog_repository.dart';
import 'package:lda_inventory/main.dart';

void main() {
  testWidgets('ordinary bootstrap fails closed without fixture products', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const LdaInventoryBootstrap(demoEnabled: false));
    await tester.pumpAndSettle();

    expect(find.text('Catalog not connected'), findsOneWidget);
    expect(find.text('Coffee'), findsNothing);
    expect(find.text('Tea'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('demo bootstrap labels fixture products persistently', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const LdaInventoryBootstrap(demoEnabled: true));
    await tester.pumpAndSettle();

    expect(find.text('Demo data · Not connected'), findsOneWidget);
    expect(find.text('Coffee'), findsOneWidget);
    expect(find.text('Tea'), findsOneWidget);
  });

  testWidgets('injected inventory catalog renders accessibly', (
    WidgetTester tester,
  ) async {
    final SemanticsHandle semantics = tester.ensureSemantics();

    try {
      await tester.pumpWidget(
        const LdaInventoryApp(
          catalogRepository: FixtureCatalogRepository(<CatalogProduct>[
            CatalogProduct(
              internalCode: 'PRD-TEST-001',
              name: 'Test product',
              quantitySpec: QuantitySpec(unit: 'piece', precision: 0),
            ),
          ]),
        ),
      );
      await tester.pumpAndSettle();

      final MaterialApp app = tester.widget(find.byType(MaterialApp));
      expect(app.title, 'LDA Inventory');
      expect(find.text('Catalog'), findsOneWidget);
      expect(find.text('Test product'), findsOneWidget);
      expect(
        find.bySemanticsLabel('QR code for Test product. Code PRD-TEST-001'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    } finally {
      semantics.dispose();
    }
  });
}
