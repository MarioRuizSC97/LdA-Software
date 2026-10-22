import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/app/inventory_theme.dart';
import 'package:lda_inventory/auth/emulator_session.dart';
import 'package:lda_inventory/catalog/catalog_page.dart';
import 'package:lda_inventory/catalog/catalog_repository.dart';
import 'package:lda_inventory/catalog/product_creation.dart';

void _expectPill(InputBorder? border) {
  expect(border, isA<OutlineInputBorder>());
  final radius = (border! as OutlineInputBorder).borderRadius;
  expect(radius.topLeft.x, greaterThanOrEqualTo(24));
  expect(radius, BorderRadius.circular(radius.topLeft.x));
}

void main() {
  for (final brightness in Brightness.values) {
    for (final field in ['name', 'unit', 'precision']) {
      testWidgets('$field renders a pill in ${brightness.name}', (
        tester,
      ) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: brightness == Brightness.light
                ? buildInventoryTheme()
                : buildDarkInventoryTheme(),
            home: AuthenticatedCatalogPage(
              session: const EmulatorSession(
                userId: 'admin',
                email: 'admin@demo.invalid',
                role: InventoryRole.administrator,
              ),
              catalogLoader: (_) async =>
                  CatalogSnapshot(const <CatalogItem>[]),
              onLogout: () async {},
              createProduct: (_) async => const ProductCreationResult(
                productId: 'PRD-TEST',
                internalCode: 'PRD-TEST',
                replayed: false,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Crear producto'));
        await tester.pumpAndSettle();
        final fieldFinder = find.byKey(
          ValueKey<String>('create-product-$field'),
        );
        InputDecoration decoration() => tester
            .widget<InputDecorator>(
              find.descendant(
                of: fieldFinder,
                matching: find.byType(InputDecorator),
              ),
            )
            .decoration;

        // Read the mounted decorator, not the raw TextFormField configuration.
        _expectPill(decoration().border);
        if (field != 'precision') {
          await tester.tap(fieldFinder);
          await tester.pumpAndSettle();
          _expectPill(decoration().focusedBorder ?? decoration().border);
        }
        final create = find.widgetWithText(FilledButton, 'Crear');
        await tester.ensureVisible(create);
        await tester.tap(create);
        await tester.pumpAndSettle();
        expect(decoration().errorText, isNotNull);
        _expectPill(decoration().errorBorder);
        _expectPill(decoration().focusedErrorBorder);
      });
    }
  }
}
