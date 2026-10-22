// T9M/S24: the cart bar shows how many pieces are in the cart when the cart
// holds one repeated product, instead of only counting product lines. Mixed
// units keep the line count, because quantities of different units do not add.
import 'package:flutter/material.dart';

import 'package:flutter_test/flutter_test.dart';

import 'package:lda_inventory/catalog/catalog_product.dart';
import 'package:lda_inventory/sales/sale_cart_controller.dart';
import 'package:lda_inventory/sales/sale_cart_panel.dart';

import 'sale_ui_fixtures.dart';

Future<SaleCartController> _cart(
  WidgetTester tester,
  List<({String id, String quantity, QuantitySpec spec})> entries,
) async {
  final SaleCartController controller = SaleCartController(
    checkout: FakeSaleCheckout().checkout,
  );
  addTearDown(controller.dispose);
  for (final e in entries) {
    controller.saveEntry(
      productId: e.id,
      name: e.id,
      quantitySpec: e.spec,
      quantity: e.quantity,
    );
  }
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SaleCartButton(controller: controller, onPressed: () {}),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return controller;
}

void main() {
  testWidgets('a repeated product shows its piece count', (
    WidgetTester tester,
  ) async {
    await _cart(tester, [
      (
        id: pinProduct.internalCode,
        quantity: '2',
        spec: pinProduct.quantitySpec,
      ),
    ]);
    expect(find.textContaining('Carrito · 2 piece ·'), findsOneWidget);
    expect(find.textContaining('1 producto'), findsNothing);
  });

  // S24/R3-001: a uniform-unit cart always shows its summed quantity, even
  // when that quantity equals the number of lines.
  testWidgets('a single piece shows its piece count, not the line count', (
    WidgetTester tester,
  ) async {
    await _cart(tester, [
      (
        id: pinProduct.internalCode,
        quantity: '1',
        spec: pinProduct.quantitySpec,
      ),
    ]);
    expect(find.textContaining('Carrito · 1 piece ·'), findsOneWidget);
    expect(find.textContaining('producto'), findsNothing);
  });

  testWidgets('two single-unit lines of one unit add up, not count lines', (
    WidgetTester tester,
  ) async {
    await _cart(tester, [
      (
        id: pinProduct.internalCode,
        quantity: '1',
        spec: pinProduct.quantitySpec,
      ),
      (id: 'DEMO-PIN-2', quantity: '1', spec: pinProduct.quantitySpec),
    ]);
    expect(find.textContaining('Carrito · 2 piece ·'), findsOneWidget);
    expect(find.textContaining('productos'), findsNothing);
  });

  testWidgets('mixed units keep the line count', (WidgetTester tester) async {
    await _cart(tester, [
      (
        id: pinProduct.internalCode,
        quantity: '2',
        spec: pinProduct.quantitySpec,
      ),
      (
        id: ribbonProduct.internalCode,
        quantity: '1',
        spec: ribbonProduct.quantitySpec,
      ),
    ]);
    expect(find.textContaining('Carrito · 2 productos ·'), findsOneWidget);
    expect(find.textContaining('piece'), findsNothing);
  });

  testWidgets('two lines of the same unit add up', (WidgetTester tester) async {
    await _cart(tester, [
      (
        id: pinProduct.internalCode,
        quantity: '2',
        spec: pinProduct.quantitySpec,
      ),
      (id: 'DEMO-PIN-2', quantity: '1', spec: pinProduct.quantitySpec),
    ]);
    expect(find.textContaining('Carrito · 3 piece ·'), findsOneWidget);
  });
}
