// T9 review follow-ups for the card sale control swap (R3-002, R3-003):
// leaving the quantity entry is as instant as opening it, and the outgoing
// control of an animated swap is hidden from assistive technology.
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import 'package:flutter_test/flutter_test.dart';

import 'package:lda_inventory/auth/emulator_session.dart';
import 'package:lda_inventory/catalog/catalog_page.dart';

import 'sale_ui_fixtures.dart';

const EmulatorSession _seller = EmulatorSession(
  userId: 'seller-north',
  email: 'seller@demo.invalid',
  role: InventoryRole.seller,
  branchId: 'branch-north',
);

Finder _key(String value) => find.byKey(ValueKey<String>(value));

Future<void> _pump(WidgetTester tester) async {
  await tester.pumpWidget(
    MaterialApp(
      home: AuthenticatedCatalogPage(
        session: _seller,
        catalogLoader: (_) async => sellerSaleSnapshot(),
        onLogout: () async {},
        saleCheckout: FakeSaleCheckout().checkout,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('closing the quantity entry returns to the stepper at once', (
    WidgetTester tester,
  ) async {
    final String id = ribbonProduct.internalCode;
    await _pump(tester);
    await tester.tap(_key('sale-add-$id'));
    await tester.pumpAndSettle();
    await tester.tap(_key('sale-line-edit-$id'));
    await tester.pumpAndSettle();
    expect(_key('sale-quantity-$id'), findsOneWidget);

    await tester.tap(_key('sale-entry-cancel-$id'));
    await tester.pump();

    expect(_key('sale-quantity-$id'), findsNothing);
    expect(_key('sale-line-edit-$id'), findsOneWidget);
  });

  testWidgets('the outgoing Agregar is hidden from semantics mid-swap', (
    WidgetTester tester,
  ) async {
    final SemanticsHandle semantics = tester.ensureSemantics();
    final String id = ribbonProduct.internalCode;
    await _pump(tester);
    // Searches the live semantics tree, so an excluded node is not found.
    final FinderBase<SemanticsNode> agregar = find.semantics.byLabel(
      'Agregar ${ribbonProduct.name} al carrito',
    );
    expect(agregar, findsOneWidget);

    await tester.tap(_key('sale-add-$id'));
    await tester.pump(const Duration(milliseconds: 60));

    expect(_key('sale-add-$id'), findsOneWidget);
    expect(agregar, findsNothing);
    await tester.pumpAndSettle();
    expect(_key('sale-add-$id'), findsNothing);
    semantics.dispose();
  });
}
