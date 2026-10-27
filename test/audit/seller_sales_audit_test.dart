import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/auth/emulator_session.dart';
import 'package:lda_inventory/catalog/catalog_page.dart';
import 'package:lda_inventory/catalog/catalog_stock.dart';
import 'package:lda_inventory/firebase/emulator_sale_gateway.dart';

import '../sales/sale_ui_fixtures.dart';
import '../support/viewport.dart';

Finder _key(String key) => find.byKey(ValueKey<String>(key));
Future<void> _tap(WidgetTester tester, String key) async {
  await tester.ensureVisible(_key(key));
  await tester.pumpAndSettle();
  await tester.tap(_key(key));
  await tester.pumpAndSettle();
}

Widget _page(FakeSaleCheckout sales, {Brightness brightness = Brightness.light,
  CatalogSnapshot? snapshot}) => MaterialApp(
  theme: ThemeData(brightness: brightness),
  home: AuthenticatedCatalogPage(
    session: const EmulatorSession(userId: 'seller-north',
      email: 'seller@demo.invalid', role: InventoryRole.seller,
      branchId: 'branch-north'),
    catalogLoader: (_) async => snapshot ?? sellerSaleSnapshot(),
    onLogout: () async {}, saleCheckout: sales.checkout,
  ),
);

Future<void> _mount(WidgetTester tester, FakeSaleCheckout sales,
    {Brightness brightness = Brightness.light}) async {
  await tester.pumpWidget(_page(sales, brightness: brightness));
  await tester.pumpAndSettle();
}

void _privateDataAbsent() {
  expect(find.textContaining(RegExp(r'Costo de adquisición|costCentavos|purchaseCost',
    caseSensitive: false)), findsNothing);
  expect(find.bySemanticsLabel(RegExp(r'Costo de adquisición|costCentavos|purchaseCost',
    caseSensitive: false)), findsNothing);
}

void main() {
  for (final width in <double>[320, 400, 600, 1200]) {
    for (final brightness in Brightness.values) {
      testWidgets('sale lifecycle ${width.toInt()}px ${brightness.name} scale 1.3', (tester) async {
        useViewport(tester, Size(width, 900), 1.3);
        final sales = FakeSaleCheckout();
        await _mount(tester, sales, brightness: brightness);
        expect(tester.takeException(), isNull, reason: 'catalog / floating cart');
        expect(find.bySemanticsLabel('Abrir carrito. Carrito vacío'), findsOneWidget);
        await _tap(tester, 'sale-cart-button');
        expect(find.textContaining('El carrito está vacío.'), findsOneWidget);
        expect(tester.widget<FilledButton>(_key('sale-charge')).onPressed, isNull);
        expect(tester.takeException(), isNull, reason: 'empty cart');
        await _tap(tester, 'sale-close-cart');
        await _tap(tester, 'sale-add-DEMO-PIN');
        await _tap(tester, 'sale-add-DEMO-RIBBON');
        _privateDataAbsent();
        expect(tester.takeException(), isNull, reason: 'populated steppers');
        await _tap(tester, 'sale-cart-button');
        expect(find.text('12.50 MXN'), findsWidgets);
        await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
        _privateDataAbsent();
        expect(tester.takeException(), isNull, reason: 'populated cart');
        // Seguir vendiendo must preserve both lines and their authoritative total.
        expect(find.text('Seguir vendiendo'), findsOneWidget);
        await _tap(tester, 'sale-close-cart');
        await _tap(tester, 'sale-cart-button');
        expect(find.text('12.50 MXN'), findsWidgets);
        await _tap(tester, 'sale-payment-transfer');
        await _tap(tester, 'sale-charge');
        expect(sales.submittedDrafts.single.amountCentavos, 1250);
        expect(find.text('Venta registrada'), findsOneWidget);
        expect(find.text('12.50 MXN'), findsWidgets);
        _privateDataAbsent();
        expect(tester.takeException(), isNull, reason: 'receipt');
        await _tap(tester, 'sale-receipt-new');
        expect(find.bySemanticsLabel('Abrir carrito. Carrito vacío'), findsOneWidget);
        expect(sales.store.completedFor('seller-north', 'branch-north'), isNull);
        expect(tester.takeException(), isNull, reason: 'Nueva venta');
      });
    }
  }

  testWidgets('rapid double charge and double retry send one attempt each with the same key', (tester) async {
    final gate = Completer<void>();
    final sales = FakeSaleCheckout()..holdSubmit = gate
      ..submitFailures.add(const SaleUncertainException());
    await _mount(tester, sales);
    await _tap(tester, 'sale-add-DEMO-PIN');
    await _tap(tester, 'sale-cart-button');
    await tester.ensureVisible(_key('sale-charge'));
    await tester.tap(_key('sale-charge'));
    await tester.tap(_key('sale-charge'));
    await tester.pump();
    expect(sales.submittedDrafts, hasLength(1));
    gate.complete();
    await tester.pumpAndSettle();
    final retryGate = Completer<void>();
    sales.holdSubmit = retryGate;
    await tester.ensureVisible(_key('sale-retry-submit'));
    await tester.tap(_key('sale-retry-submit'));
    await tester.tap(_key('sale-retry-submit'));
    await tester.pump();
    expect(sales.submittedDrafts, hasLength(2));
    expect(sales.submittedDrafts.last, same(sales.submittedDrafts.first));
    retryGate.complete();
    await tester.pumpAndSettle();
    expect(find.text('Venta registrada'), findsOneWidget);
  });

  for (final submit in <bool>[false, true]) {
    testWidgets('${submit ? 'submit' : 'quote'} rejection never displays raw English backend text', (tester) async {
      final sales = FakeSaleCheckout();
      const rejection = SaleRejectedException(code: 'failed-precondition',
        message: 'product has no price: internal-product-897');
      if (!submit) sales.quoteFailures.add(rejection);
      await _mount(tester, sales);
      await _tap(tester, 'sale-add-DEMO-PIN');
      await _tap(tester, 'sale-cart-button');
      if (submit) {
        sales.submitFailures.add(rejection);
        await _tap(tester, 'sale-charge');
      }
      // T22 D2 and Seller Sale UI decision 8: neutral professional Spanish.
      expect(find.textContaining(rejection.message), findsNothing);
      expect(find.textContaining('internal-product-897'), findsNothing);
      expect(sales.submittedDrafts, hasLength(submit ? 1 : 0));
    });
  }

  for (final systemBack in <bool>[false, true]) {
    testWidgets('${systemBack ? 'system back' : 'header Volver'} leaves cart intact', (tester) async {
      final sales = FakeSaleCheckout();
      await _mount(tester, sales);
      await _tap(tester, 'sale-add-DEMO-PIN');
      await _tap(tester, 'sale-cart-button');
      if (systemBack) {
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
      } else {
        await _tap(tester, 'panel-back');
      }
      expect(_key('sale-charge'), findsNothing);
      await _tap(tester, 'sale-cart-button');
      expect(find.text('2.50 MXN'), findsWidgets);
      expect(sales.submittedDrafts, isEmpty);
    });
  }

  testWidgets('loading and failed quote do not fabricate a zero total', (tester) async {
    final sales = FakeSaleCheckout()..holdQuotes = true;
    await _mount(tester, sales);
    await _tap(tester, 'sale-add-DEMO-PIN');
    await _tap(tester, 'sale-cart-button');
    expect(find.textContaining('Calculando'), findsWidgets);
    expect(find.text('0.00 MXN'), findsNothing);
    expect(tester.widget<FilledButton>(_key('sale-charge')).onPressed, isNull);
    sales.heldQuotes.single.completeError(const SaleUncertainException());
    await tester.pumpAndSettle();
    expect(find.text('No se pudo calcular el total'), findsOneWidget);
    expect(find.text('0.00 MXN'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('fractional stock cap and minimum survive repeated taps and invalid edits', (tester) async {
    final sales = FakeSaleCheckout();
    await tester.pumpWidget(_page(sales, snapshot: CatalogSnapshot(<CatalogItem>[
      CatalogItem(product: ribbonProduct, holdings: <CatalogHolding>[
        CatalogHolding(branchId: 'branch-north', quantityScaled: 101),
      ]),
    ])));
    await tester.pumpAndSettle();
    await _tap(tester, 'sale-add-DEMO-RIBBON');
    await _tap(tester, 'sale-line-edit-DEMO-RIBBON');
    await tester.enterText(_key('sale-quantity-DEMO-RIBBON'), '1.01');
    await _tap(tester, 'sale-entry-save-DEMO-RIBBON');
    expect(tester.widget<IconButton>(_key('sale-line-increment-DEMO-RIBBON')).onPressed, isNull);
    await _tap(tester, 'sale-line-edit-DEMO-RIBBON');
    for (final invalid in <String>['1.02', '0', '-0.01']) {
      await tester.enterText(_key('sale-quantity-DEMO-RIBBON'), invalid);
      await _tap(tester, 'sale-entry-save-DEMO-RIBBON');
      expect(sales.quotedCarts.last.lines.single.quantityScaled, 101);
    }
    await tester.enterText(_key('sale-quantity-DEMO-RIBBON'), '0.01');
    await _tap(tester, 'sale-entry-save-DEMO-RIBBON');
    // A decrement may remove the line, but never creates a non-positive quantity.
    await _tap(tester, 'sale-line-remove-DEMO-RIBBON');
    for (final cart in sales.quotedCarts) {
      for (final line in cart.lines) {
        expect(line.quantityScaled, inInclusiveRange(1, 101));
      }
    }
    expect(tester.takeException(), isNull);
  });
}
