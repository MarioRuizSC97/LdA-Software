// T9K/S22: the page's entry buttons ('Crear producto' and the cart bar) follow
// the same softer tonal treatment as the card's 'Agregar'.
import 'package:flutter/material.dart';

import 'package:flutter_test/flutter_test.dart';

import 'package:lda_inventory/app/inventory_theme.dart';
import 'package:lda_inventory/auth/emulator_session.dart';
import 'package:lda_inventory/catalog/catalog_page.dart';
import 'package:lda_inventory/sales/sale_cart_controller.dart';
import 'package:lda_inventory/sales/sale_cart_panel.dart';

import '../sales/sale_ui_fixtures.dart';

final EmulatorSession _administrator = EmulatorSession(
  userId: 'admin-1',
  email: 'admin@demo.invalid',
  role: InventoryRole.administrator,
  branchId: null,
);

Future<void> _pump(WidgetTester tester) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildInventoryTheme(),
      home: AuthenticatedCatalogPage(
        session: _administrator,
        catalogLoader: (_) async => sellerSaleSnapshot(),
        onLogout: () async {},
        createProduct: (_) async => throw UnimplementedError(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('Crear producto uses the soft tonal fill', (
    WidgetTester tester,
  ) async {
    await _pump(tester);
    final ColorScheme colors = buildInventoryTheme().colorScheme;
    final Finder button = find.ancestor(
      of: find.text('Crear producto'),
      matching: find.byType(Material),
    );
    expect(button, findsWidgets);
    final Color? fill = tester.widget<Material>(button.first).color;
    expect(fill, colors.secondaryContainer);
    expect(fill, isNot(colors.primary));
  });

  testWidgets('Crear producto still opens the creation form', (
    WidgetTester tester,
  ) async {
    await _pump(tester);
    await tester.tap(find.text('Crear producto'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('create-product-name')),
      findsOneWidget,
    );
  });

  testWidgets('the cart bar button uses the soft tonal fill', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildInventoryTheme(),
        home: Scaffold(
          body: SaleCartButton(
            controller: SaleCartController(
              checkout: FakeSaleCheckout().checkout,
            ),
            onPressed: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final ColorScheme colors = buildInventoryTheme().colorScheme;
    final Finder button = find.ancestor(
      of: find.text('Carrito vacío'),
      matching: find.byType(FilledButton),
    );
    expect(button, findsOneWidget);
    final Color? fill = tester
        .widget<Material>(
          find.descendant(of: button, matching: find.byType(Material)).first,
        )
        .color;
    expect(fill, colors.secondaryContainer);
    expect(fill, isNot(colors.primary));
  });
}
