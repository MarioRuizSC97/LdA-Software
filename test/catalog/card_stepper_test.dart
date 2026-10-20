// T11 / S11: the product card sale action becomes the cart quantity stepper
// once the product is in the cart. Before that, the card keeps 'Agregar'.
// The card stepper is the same widget the cart line uses (T3), bound to the
// same cart line, so card and cart stay in sync: trash at quantity 1 / minus
// above, the quantity (tap to type), and plus.
import 'package:flutter/material.dart';

import 'package:flutter_test/flutter_test.dart';

import 'package:lda_inventory/auth/emulator_session.dart';
import 'package:lda_inventory/catalog/catalog_page.dart';

import '../sales/sale_ui_fixtures.dart';
import '../support/viewport.dart';

const EmulatorSession _seller = EmulatorSession(
  userId: 'seller-north',
  email: 'seller@demo.invalid',
  role: InventoryRole.seller,
  branchId: 'branch-north',
);

Widget _sellerApp() => MaterialApp(
  home: AuthenticatedCatalogPage(
    session: _seller,
    catalogLoader: (_) async => sellerSaleSnapshot(),
    onLogout: () async {},
    saleCheckout: FakeSaleCheckout().checkout,
  ),
);

/// Like [_sellerApp] but exposing the fake backend for assertions.
Widget _sellerAppWith(FakeSaleCheckout sales) => MaterialApp(
  home: AuthenticatedCatalogPage(
    session: _seller,
    catalogLoader: (_) async => sellerSaleSnapshot(),
    onLogout: () async {},
    saleCheckout: sales.checkout,
  ),
);

Finder _key(String value) => find.byKey(ValueKey<String>(value));

Future<void> _tap(WidgetTester tester, String key) async {
  await tester.ensureVisible(_key(key));
  await tester.pumpAndSettle();
  await tester.tap(_key(key), warnIfMissed: false);
  await tester.pumpAndSettle();
}

/// Adds [productId] from the card with a typed quantity, as today (T3
/// hybrid): 'Agregar' opens the inline quantity entry.
Future<void> _addToCartFromCard(
  WidgetTester tester,
  String productId,
  String quantity,
) async {
  await _tap(tester, 'sale-add-$productId');
  await tester.enterText(_key('sale-quantity-$productId'), quantity);
  await _tap(tester, 'sale-entry-save-$productId');
}

void main() {
  testWidgets('the card keeps Agregar for products not in the cart', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_sellerApp());
    await tester.pumpAndSettle();

    expect(_key('sale-add-DEMO-RIBBON'), findsOneWidget);
    expect(_key('sale-add-DEMO-PIN'), findsOneWidget);
    expect(_key('sale-line-increment-DEMO-RIBBON'), findsNothing);
    expect(_key('sale-line-increment-DEMO-PIN'), findsNothing);
  });

  testWidgets('adding from the card switches it to the cart stepper', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_sellerApp());
    await tester.pumpAndSettle();

    await _addToCartFromCard(tester, 'DEMO-RIBBON', '2');

    // The same stepper the cart line uses (T3) replaces 'Agregar' on the
    // card; the other product is still not in the cart.
    expect(_key('sale-line-increment-DEMO-RIBBON'), findsOneWidget);
    expect(_key('sale-line-edit-DEMO-RIBBON'), findsOneWidget);
    // Quantity 2 is above one unit, so the left control is a minus.
    expect(_key('sale-line-decrement-DEMO-RIBBON'), findsOneWidget);
    expect(_key('sale-line-remove-DEMO-RIBBON'), findsOneWidget);
    expect(_key('sale-add-DEMO-RIBBON'), findsNothing);
    expect(_key('sale-add-DEMO-PIN'), findsOneWidget);
  });

  testWidgets('the card stepper and the cart share one cart line', (
    WidgetTester tester,
  ) async {
    final FakeSaleCheckout sales = FakeSaleCheckout();
    await tester.pumpWidget(_sellerAppWith(sales));
    await tester.pumpAndSettle();

    await _addToCartFromCard(tester, 'DEMO-RIBBON', '2');
    final int quotesAfterAdd = sales.quotedCarts.length;

    // Step on the card... (stepped precision-2 quantities format like the
    // cart stepper does, T3)
    await _tap(tester, 'sale-line-increment-DEMO-RIBBON');
    expect(sales.quotedCarts.length, quotesAfterAdd + 1);
    expect(sales.quotedCarts.last.lines.single.quantity, '3.00');

    // ...and find the same quantity in the cart.
    await _tap(tester, 'sale-cart-button');
    expect(find.text('3.00 meter'), findsOneWidget);

    // Step in the cart, close it, and the card shows the synced quantity.
    await _tap(tester, 'sale-line-decrement-DEMO-RIBBON');
    expect(sales.quotedCarts.last.lines.single.quantity, '2.00');
    await _tap(tester, 'sale-close-cart');

    expect(_key('sale-line-increment-DEMO-RIBBON'), findsOneWidget);
    await _tap(tester, 'sale-line-remove-DEMO-RIBBON');
    expect(_key('sale-add-DEMO-RIBBON'), findsOneWidget);
  });

  testWidgets('trash at quantity 1 removes the line and the card returns to '
      'Agregar', (WidgetTester tester) async {
    await tester.pumpWidget(_sellerApp());
    await tester.pumpAndSettle();

    await _addToCartFromCard(tester, 'DEMO-PIN', '1');

    // Exactly one unit: the left control is the trash icon, not a minus.
    expect(_key('sale-line-decrement-DEMO-PIN'), findsNothing);
    expect(_key('sale-line-remove-DEMO-PIN'), findsOneWidget);

    await _tap(tester, 'sale-line-remove-DEMO-PIN');
    expect(_key('sale-add-DEMO-PIN'), findsOneWidget);
    expect(_key('sale-line-increment-DEMO-PIN'), findsNothing);
  });

  testWidgets('tapping the quantity on the card keeps the typed validation', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_sellerApp());
    await tester.pumpAndSettle();

    await _addToCartFromCard(tester, 'DEMO-PIN', '1');

    await _tap(tester, 'sale-line-edit-DEMO-PIN');
    await tester.enterText(_key('sale-quantity-DEMO-PIN'), '1.5');
    await _tap(tester, 'sale-entry-save-DEMO-PIN');

    // Pin has precision 0: the same canonical error as the cart stepper.
    expect(
      find.text('Este producto solo admite cantidades enteras.'),
      findsOneWidget,
    );
    expect(find.textContaining('Cantidad (piece)'), findsOneWidget);
  });

  testWidgets('cancel on the card entry returns to the stepper', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_sellerApp());
    await tester.pumpAndSettle();

    await _addToCartFromCard(tester, 'DEMO-PIN', '1');
    await _tap(tester, 'sale-line-edit-DEMO-PIN');
    await tester.enterText(_key('sale-quantity-DEMO-PIN'), '4');
    await _tap(tester, 'sale-entry-cancel-DEMO-PIN');

    expect(_key('sale-line-increment-DEMO-PIN'), findsOneWidget);
    expect(_key('sale-quantity-DEMO-PIN'), findsNothing);
  });

  testWidgets('the card stepper does not overflow at text scale 2 on a 360px '
      'phone', (WidgetTester tester) async {
    useViewport(tester, const Size(360, 800), 2);
    await tester.pumpWidget(_sellerApp());
    await tester.pumpAndSettle();

    await _addToCartFromCard(tester, 'DEMO-PIN', '3');

    expect(_key('sale-line-increment-DEMO-PIN'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
