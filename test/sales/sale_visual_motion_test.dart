// T9/S6: brief, useful sale motion. The 'Agregar' → stepper swap and the
// quantity number update cross-fade quickly, the cart panel eases in on
// open, nothing animates on initial load, and MediaQuery.disableAnimations
// (reduced motion) removes every transition. Outgoing controls never take a
// second action, duplicate a key, or linger as stale buttons.
import 'package:flutter/material.dart';

import 'package:flutter_test/flutter_test.dart';

import 'package:lda_inventory/auth/emulator_session.dart';
import 'package:lda_inventory/catalog/catalog_page.dart';
import 'package:lda_inventory/catalog/catalog_repository.dart';
import 'package:lda_inventory/catalog/catalog_stock.dart';
import 'package:lda_inventory/sales/sale_cart_controller.dart';
import 'package:lda_inventory/sales/sale_cart_panel.dart';

import 'sale_ui_fixtures.dart';

const EmulatorSession _seller = EmulatorSession(
  userId: 'seller-north',
  email: 'seller@demo.invalid',
  role: InventoryRole.seller,
  branchId: 'branch-north',
);

Finder _key(String value) => find.byKey(ValueKey<String>(value));

Widget _sellerApp(FakeSaleCheckout sales) => MaterialApp(
  home: AuthenticatedCatalogPage(
    session: _seller,
    catalogLoader: (_) async => sellerSaleSnapshot(),
    onLogout: () async {},
    saleCheckout: sales.checkout,
  ),
);

Widget _outOfStockApp(FakeSaleCheckout sales, {int pin = 0, int? ribbon}) =>
    MaterialApp(
      home: AuthenticatedCatalogPage(
        session: _seller,
        catalogLoader: (_) async => CatalogSnapshot(<CatalogItem>[
          CatalogItem(
            product: pinProduct,
            holdings: <CatalogHolding>[
              CatalogHolding(branchId: 'branch-north', quantityScaled: pin),
            ],
          ),
          if (ribbon != null)
            CatalogItem(
              product: ribbonProduct,
              holdings: <CatalogHolding>[
                CatalogHolding(
                  branchId: 'branch-north',
                  quantityScaled: ribbon,
                ),
              ],
            ),
        ]),
        onLogout: () async {},
        saleCheckout: sales.checkout,
      ),
    );

void _useReducedMotion(WidgetTester tester) {
  tester.platformDispatcher.accessibilityFeaturesTestValue =
      FakeAccessibilityFeatures(disableAnimations: true);
  addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
}

/// The motion wrapper's transition config for the first mounted control.
AnimatedSwitcher _firstSwap(WidgetTester tester) =>
    tester.widget<AnimatedSwitcher>(find.byType(AnimatedSwitcher).first);

void main() {
  testWidgets('the catalog does not animate on initial load', (
    WidgetTester tester,
  ) async {
    final FakeSaleCheckout sales = FakeSaleCheckout();
    await tester.pumpWidget(_sellerApp(sales));
    await tester.pump();

    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('Agregar swaps to the stepper with a brief cross-fade', (
    WidgetTester tester,
  ) async {
    final FakeSaleCheckout sales = FakeSaleCheckout();
    await tester.pumpWidget(_sellerApp(sales));
    await tester.pumpAndSettle();

    await tester.tap(_key('sale-add-DEMO-RIBBON'));
    await tester.pump();
    // S6: mid-swap both controls coexist in the fade; without motion this
    // assertion fails because the button disappears immediately.
    expect(_key('sale-add-DEMO-RIBBON'), findsOneWidget);
    expect(_key('sale-line-edit-DEMO-RIBBON'), findsOneWidget);
    final AnimatedSwitcher swap = _firstSwap(tester);
    expect(swap.duration, greaterThan(Duration.zero));
    await tester.pumpAndSettle();

    // The swap settles into exactly one control: add-one semantics intact.
    expect(tester.binding.transientCallbackCount, 0);
    expect(_key('sale-add-DEMO-RIBBON'), findsNothing);
    expect(_key('sale-line-edit-DEMO-RIBBON'), findsOneWidget);
    expect(
      find.descendant(
        of: _key('sale-line-edit-DEMO-RIBBON'),
        matching: find.text('1'),
      ),
      findsOneWidget,
    );
    expect(sales.quotedCarts.single.lines.single.quantity, '1');
  });

  testWidgets('a fast second tap during the swap never adds twice', (
    WidgetTester tester,
  ) async {
    final FakeSaleCheckout sales = FakeSaleCheckout();
    await tester.pumpWidget(_sellerApp(sales));
    await tester.pumpAndSettle();

    final Offset addCenter = tester.getCenter(_key('sale-add-DEMO-RIBBON'));
    await tester.tap(_key('sale-add-DEMO-RIBBON'));
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tapAt(addCenter);
    await tester.pumpAndSettle();

    // Exactly one unit is in the cart: the outgoing control cannot act.
    expect(sales.quotedCarts, hasLength(1));
    expect(sales.quotedCarts.single.lines.single.quantity, '1');
  });

  testWidgets('reduced motion swaps Agregar without any transition', (
    WidgetTester tester,
  ) async {
    _useReducedMotion(tester);
    final FakeSaleCheckout sales = FakeSaleCheckout();
    await tester.pumpWidget(_sellerApp(sales));
    await tester.pumpAndSettle();

    await tester.tap(_key('sale-add-DEMO-RIBBON'));
    await tester.pump();
    // The swap is instant: no outgoing control lingers.
    expect(_key('sale-add-DEMO-RIBBON'), findsNothing);
    expect(_key('sale-line-edit-DEMO-RIBBON'), findsOneWidget);
    expect(_firstSwap(tester).duration, Duration.zero);
    await tester.pumpAndSettle();

    expect(sales.quotedCarts.single.lines.single.quantity, '1');
  });

  testWidgets('stepping the quantity eases the number update', (
    WidgetTester tester,
  ) async {
    final FakeSaleCheckout sales = FakeSaleCheckout();
    await tester.pumpWidget(_sellerApp(sales));
    await tester.pumpAndSettle();
    await tester.tap(_key('sale-add-DEMO-RIBBON'));
    await tester.pumpAndSettle();

    await tester.tap(_key('sale-line-increment-DEMO-RIBBON'));
    await tester.pump();
    // The old quantity fades out while the new one fades in.
    expect(find.text('1'), findsOneWidget);
    expect(find.text('2.00'), findsOneWidget);
    await tester.pumpAndSettle();

    expect(_key('sale-line-edit-DEMO-RIBBON'), findsOneWidget);
    expect(find.text('1'), findsNothing);
    expect(
      find.descendant(
        of: _key('sale-line-edit-DEMO-RIBBON'),
        matching: find.text('2.00'),
      ),
      findsOneWidget,
    );
    expect(sales.quotedCarts.last.lines.single.quantity, '2.00');
  });

  testWidgets('clearing the line returns to Agregar without stale buttons', (
    WidgetTester tester,
  ) async {
    final FakeSaleCheckout sales = FakeSaleCheckout();
    await tester.pumpWidget(_sellerApp(sales));
    await tester.pumpAndSettle();
    await tester.tap(_key('sale-add-DEMO-RIBBON'));
    await tester.pumpAndSettle();

    await tester.tap(_key('sale-line-remove-DEMO-RIBBON'));
    await tester.pumpAndSettle();

    expect(tester.binding.transientCallbackCount, 0);
    expect(_key('sale-add-DEMO-RIBBON'), findsOneWidget);
    expect(_key('sale-line-edit-DEMO-RIBBON'), findsNothing);
    expect(_key('sale-line-increment-DEMO-RIBBON'), findsNothing);
    expect(_key('sale-line-remove-DEMO-RIBBON'), findsNothing);
  });

  testWidgets('a stocked-out product keeps a disabled Agotado control', (
    WidgetTester tester,
  ) async {
    final FakeSaleCheckout sales = FakeSaleCheckout();
    await tester.pumpWidget(_outOfStockApp(sales, pin: 0, ribbon: 99));
    await tester.pumpAndSettle();

    // Zero stock and below-one-unit stock both disable 'Agregar' as
    // 'Agotado'; the control is the requested primary FilledButton (S3).
    for (final String id in <String>['DEMO-PIN', 'DEMO-RIBBON']) {
      final FilledButton agotado = tester.widget<FilledButton>(
        _key('sale-add-$id'),
      );
      expect(agotado.onPressed, isNull);
      expect(
        find.descendant(
          of: _key('sale-add-$id'),
          matching: find.text('Agotado'),
        ),
        findsOneWidget,
      );
    }
    expect(find.bySemanticsLabel('Pin: Agotado'), findsOneWidget);
    expect(sales.quotedCarts, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('unknown branch stock keeps Agregar enabled and adds one', (
    WidgetTester tester,
  ) async {
    final FakeSaleCheckout sales = FakeSaleCheckout();
    final SaleCartController controller = SaleCartController(
      checkout: sales.checkout,
      availableScaled: (_) => null,
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SaleAddControl(controller: controller, product: pinProduct),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final FilledButton agregar = tester.widget<FilledButton>(
      _key('sale-add-DEMO-PIN'),
    );
    expect(agregar.onPressed, isNotNull);
    await tester.tap(_key('sale-add-DEMO-PIN'));
    await tester.pumpAndSettle();
    expect(sales.quotedCarts.single.lines.single.quantity, '1');
  });

  testWidgets('opening the cart panel eases in and stays interactive', (
    WidgetTester tester,
  ) async {
    final FakeSaleCheckout sales = FakeSaleCheckout();
    await tester.pumpWidget(_sellerApp(sales));
    await tester.pumpAndSettle();
    await tester.tap(_key('sale-add-DEMO-PIN'));
    await tester.pumpAndSettle();

    await tester.tap(_key('sale-cart-button'));
    await tester.pump();
    expect(find.text('Carrito'), findsOneWidget);
    // S6: the panel entrance animates from a slightly faded, offset state.
    final TweenAnimationBuilder<double> entrance = tester
        .widget<TweenAnimationBuilder<double>>(
          find.byType(TweenAnimationBuilder<double>),
        );
    expect(entrance.tween.begin, 0);
    expect(entrance.duration, greaterThan(Duration.zero));
    await tester.pumpAndSettle();

    expect(find.text('Carrito'), findsOneWidget);
    expect(find.text('Método de pago'), findsOneWidget);
  });

  testWidgets('reduced motion opens the cart panel without animation', (
    WidgetTester tester,
  ) async {
    _useReducedMotion(tester);
    final FakeSaleCheckout sales = FakeSaleCheckout();
    await tester.pumpWidget(_sellerApp(sales));
    await tester.pumpAndSettle();
    await tester.tap(_key('sale-add-DEMO-PIN'));
    await tester.pumpAndSettle();

    await tester.tap(_key('sale-cart-button'));
    await tester.pump();
    expect(find.text('Carrito'), findsOneWidget);
    final TweenAnimationBuilder<double> entrance = tester
        .widget<TweenAnimationBuilder<double>>(
          find.byType(TweenAnimationBuilder<double>),
        );
    expect(entrance.tween.begin, 1);
    expect(entrance.duration, Duration.zero);
    await tester.pumpAndSettle();

    expect(find.text('Método de pago'), findsOneWidget);
  });
}
