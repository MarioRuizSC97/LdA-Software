import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/catalog/catalog_product.dart';
import 'package:lda_inventory/sales/sale_cart.dart';
import 'package:lda_inventory/sales/sale_cart_controller.dart';
import 'package:lda_inventory/sales/sale_cart_panel.dart';

import 'sale_ui_fixtures.dart';

Finder _key(String value) => find.byKey(ValueKey<String>(value));

Future<void> _tap(WidgetTester tester, String key) async {
  await tester.ensureVisible(_key(key));
  await tester.tap(_key(key));
  await tester.pumpAndSettle();
}

Future<SaleCartController> _mount(
  WidgetTester tester,
  FakeSaleCheckout sales, {
  CatalogProduct product = pinProduct,
  String quantity = '1',
}) async {
  final SaleCartController controller = SaleCartController(
    checkout: sales.checkout,
  );
  addTearDown(controller.dispose);
  controller.saveEntry(
    productId: product.internalCode,
    name: product.name,
    quantitySpec: product.quantitySpec,
    quantity: quantity,
  );
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SaleCartPanel(controller: controller, onClose: () {}),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return controller;
}

void main() {
  for (final double width in <double>[390, 1100]) {
    testWidgets('stepper adds, subtracts and removes at width $width', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final FakeSaleCheckout sales = FakeSaleCheckout();
      final SaleCartController controller = await _mount(tester, sales);

      expect(find.byTooltip('Quitar Pin del carrito'), findsWidgets);
      await _tap(tester, 'sale-line-increment-DEMO-PIN');
      expect(controller.cart.lines.single.quantity, '2');
      expect(sales.quotedCarts, hasLength(2));
      expect(sales.quotedCarts.last.lines.single.quantity, '2');
      expect(find.text('5.00 MXN'), findsWidgets);
      expect(find.byTooltip('Disminuir cantidad de Pin'), findsOneWidget);

      await _tap(tester, 'sale-line-decrement-DEMO-PIN');
      expect(controller.cart.lines.single.quantity, '1');
      expect(sales.quotedCarts, hasLength(3));
      expect(find.text('2.50 MXN'), findsWidgets);
      await _tap(tester, 'sale-line-remove-DEMO-PIN');
      expect(controller.cart.isEmpty, isTrue);
      expect(sales.quotedCarts, hasLength(3));
      expect(find.textContaining('El carrito está vacío.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('tapping quantity keeps typed validation and cancel behavior', (
    WidgetTester tester,
  ) async {
    final FakeSaleCheckout sales = FakeSaleCheckout();
    final SaleCartController controller = await _mount(tester, sales);
    expect(
      find.descendant(
        of: _key('sale-line-edit-DEMO-PIN'),
        matching: find.text('1'),
      ),
      findsOneWidget,
    );
    await _tap(tester, 'sale-line-edit-DEMO-PIN');
    await tester.enterText(_key('sale-quantity-DEMO-PIN'), '1.5');
    await _tap(tester, 'sale-entry-save-DEMO-PIN');
    expect(
      find.text('Este producto solo admite cantidades enteras.'),
      findsOneWidget,
    );
    expect(controller.cart.lines.single.quantity, '1');
    expect(sales.quotedCarts, hasLength(1));
    await _tap(tester, 'sale-entry-cancel-DEMO-PIN');
    expect(controller.cart.lines.single.quantity, '1');
    expect(sales.quotedCarts, hasLength(1));
    await _tap(tester, 'sale-line-edit-DEMO-PIN');
    await tester.enterText(_key('sale-quantity-DEMO-PIN'), '4');
    await _tap(tester, 'sale-entry-save-DEMO-PIN');
    expect(controller.cart.lines.single.quantity, '4');
    expect(sales.quotedCarts, hasLength(2));
    expect(find.text('10.00 MXN'), findsWidgets);
  });

  testWidgets('fractional quantities step by one unit without rounding', (
    WidgetTester tester,
  ) async {
    final FakeSaleCheckout sales = FakeSaleCheckout();
    final SaleCartController controller = await _mount(
      tester,
      sales,
      product: ribbonProduct,
      quantity: '1.01',
    );
    await _tap(tester, 'sale-line-increment-DEMO-RIBBON');
    expect(controller.cart.lines.single.quantityScaled, 201);
    await _tap(tester, 'sale-line-decrement-DEMO-RIBBON');
    expect(controller.cart.lines.single.quantityScaled, 101);
    await _tap(tester, 'sale-line-decrement-DEMO-RIBBON');
    expect(controller.cart.lines.single.quantityScaled, 1);
    expect(sales.quotedCarts, hasLength(4));
    expect(find.byTooltip('Quitar Ribbon del carrito'), findsWidgets);
    await _tap(tester, 'sale-line-remove-DEMO-RIBBON');
    expect(controller.cart.isEmpty, isTrue);
    expect(sales.quotedCarts, hasLength(4));
  });

  testWidgets('stepper and typed quantity stay disabled during submission', (
    WidgetTester tester,
  ) async {
    final FakeSaleCheckout sales = FakeSaleCheckout();
    final SaleCartController controller = await _mount(
      tester,
      sales,
      quantity: '2',
    );
    sales.holdSubmit = Completer<void>();
    final Future<void> submitting = controller.charge();
    await tester.pump();
    for (final String key in <String>[
      'sale-line-increment-DEMO-PIN',
      'sale-line-decrement-DEMO-PIN',
      'sale-line-remove-DEMO-PIN',
    ]) {
      final IconButton button = tester.widget(_key(key));
      expect(button.onPressed, isNull);
    }
    final TextButton edit = tester.widget(_key('sale-line-edit-DEMO-PIN'));
    expect(edit.onPressed, isNull);
    expect(controller.cart.lines.single.quantity, '2');
    expect(sales.quotedCarts, hasLength(1));
    sales.holdSubmit!.complete();
    await submitting;
    await tester.pumpAndSettle();
  });

  testWidgets('increment is disabled at safe quantity limit', (
    WidgetTester tester,
  ) async {
    final FakeSaleCheckout sales = FakeSaleCheckout()
      ..quoteFailures.add(StateError('quote unavailable'));
    final SaleCartController controller = await _mount(
      tester,
      sales,
      quantity: '$maxSafeSaleInteger',
    );
    final IconButton increment = tester.widget(
      _key('sale-line-increment-DEMO-PIN'),
    );
    expect(increment.onPressed, isNull);
    expect(controller.cart.lines.single.quantity, '$maxSafeSaleInteger');
    expect(sales.quotedCarts, hasLength(1));
    expect(controller.entryError, isNull);
  });
}
