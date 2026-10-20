import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/auth/emulator_session.dart';
import 'package:lda_inventory/catalog/catalog_page.dart';
import 'package:lda_inventory/catalog/catalog_stock.dart';
import 'package:lda_inventory/sales/sale_cart_controller.dart';
import 'package:lda_inventory/sales/sale_cart_panel.dart';

import 'sale_ui_fixtures.dart';

Finder _key(String key) => find.byKey(ValueKey<String>(key));
Future<void> _tap(WidgetTester tester, String key) async {
  await tester.ensureVisible(_key(key));
  await tester.tap(_key(key));
  await tester.pumpAndSettle();
}

class _StockCatalog {
  int? pin = 3;
  int? ribbon = 250;
  final FakeSaleCheckout sales = FakeSaleCheckout();

  CatalogSnapshot snapshot() => CatalogSnapshot([
    for (final product in [pinProduct, ribbonProduct])
      CatalogItem(
        product: product,
        holdings: [
          if ((product == pinProduct ? pin : ribbon) case final int stock)
            CatalogHolding(branchId: 'branch-north', quantityScaled: stock),
        ],
      ),
  ]);

  Future<void> mount(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: AuthenticatedCatalogPage(
          session: const EmulatorSession(
            userId: 'seller-north',
            email: 'seller@demo.invalid',
            role: InventoryRole.seller,
            branchId: 'branch-north',
          ),
          catalogLoader: (_) async => snapshot(),
          onLogout: () async {},
          saleCheckout: sales.checkout,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }
}

Future<void> _type(WidgetTester tester, String id, String quantity) async {
  await _tap(tester, 'sale-line-edit-$id');
  await tester.enterText(_key('sale-quantity-$id'), quantity);
  await _tap(tester, 'sale-entry-save-$id');
}

void main() {
  testWidgets(
    'typed over-stock quantity names the limit and preserves the cart',
    (tester) async {
      final stock = _StockCatalog();
      await stock.mount(tester);
      await _tap(tester, 'sale-add-DEMO-PIN');
      final before = stock.sales.quotedCarts.single;
      await _type(tester, 'DEMO-PIN', '4');
      expect(find.text('Solo hay 3 piece en existencia.'), findsOneWidget);
      expect(stock.sales.quotedCarts, [before]);
      await _tap(tester, 'sale-entry-cancel-DEMO-PIN');
      await _tap(tester, 'sale-cart-button');
      expect(find.text('1 piece'), findsOneWidget);
    },
  );

  testWidgets(
    'plus is enabled below stock and disabled at stock with explanation',
    (tester) async {
      final stock = _StockCatalog()..pin = 2;
      await stock.mount(tester);
      await _tap(tester, 'sale-add-DEMO-PIN');
      expect(
        tester
            .widget<IconButton>(_key('sale-line-increment-DEMO-PIN'))
            .onPressed,
        isNotNull,
      );
      await _tap(tester, 'sale-line-increment-DEMO-PIN');
      expect(
        tester
            .widget<IconButton>(_key('sale-line-increment-DEMO-PIN'))
            .onPressed,
        isNull,
      );
      expect(find.byTooltip('No hay más existencias'), findsOneWidget);
      await _tap(tester, 'sale-line-decrement-DEMO-PIN');
      expect(
        tester
            .widget<IconButton>(_key('sale-line-increment-DEMO-PIN'))
            .onPressed,
        isNotNull,
      );
    },
  );

  testWidgets(
    'precision stock uses scaled quantities and permits exact fractional limit',
    (tester) async {
      final stock = _StockCatalog();
      await stock.mount(tester);
      await _tap(tester, 'sale-add-DEMO-RIBBON');
      await _type(tester, 'DEMO-RIBBON', '2.51');
      expect(find.text('Solo hay 2.50 meter en existencia.'), findsOneWidget);
      expect(stock.sales.quotedCarts.last.lines.single.quantity, '1');
      await tester.enterText(_key('sale-quantity-DEMO-RIBBON'), '2.50');
      await _tap(tester, 'sale-entry-save-DEMO-RIBBON');
      expect(stock.sales.quotedCarts.last.lines.single.quantityScaled, 250);
      expect(
        tester
            .widget<IconButton>(_key('sale-line-increment-DEMO-RIBBON'))
            .onPressed,
        isNull,
      );
    },
  );

  testWidgets(
    'Agregar is disabled and labelled Agotado at zero and below one unit',
    (tester) async {
      final stock = _StockCatalog()
        ..pin = 0
        ..ribbon = 99;
      await stock.mount(tester);
      for (final id in ['DEMO-PIN', 'DEMO-RIBBON']) {
        expect(
          tester.widget<OutlinedButton>(_key('sale-add-$id')).onPressed,
          isNull,
        );
        expect(
          find.descendant(
            of: _key('sale-add-$id'),
            matching: find.text('Agotado'),
          ),
          findsOneWidget,
        );
      }
      expect(stock.sales.quotedCarts, isEmpty);
    },
  );

  testWidgets(
    'unknown branch stock preserves unlimited entry and stepper behavior',
    (tester) async {
      final sales = FakeSaleCheckout();
      final controller = SaleCartController(
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
      expect(
        tester.widget<OutlinedButton>(_key('sale-add-DEMO-PIN')).onPressed,
        isNotNull,
      );
      await _tap(tester, 'sale-add-DEMO-PIN');
      await _type(tester, 'DEMO-PIN', '10000');
      expect(sales.quotedCarts.last.lines.single.quantity, '10000');
      expect(
        tester
            .widget<IconButton>(_key('sale-line-increment-DEMO-PIN'))
            .onPressed,
        isNotNull,
      );
    },
  );

  test('omitted lookup keeps the controller unlimited', () {
    final controller = SaleCartController(
      checkout: FakeSaleCheckout().checkout,
    );
    addTearDown(controller.dispose);
    expect(
      controller.saveEntry(
        productId: pinProduct.internalCode,
        name: pinProduct.name,
        quantitySpec: pinProduct.quantitySpec,
        quantity: '10000',
      ),
      isTrue,
    );
    expect(controller.cart.lines.single.quantity, '10000');
  });

  testWidgets(
    'refresh lowers the live limit without changing an existing line or its quote flag',
    (tester) async {
      final stock = _StockCatalog();
      await stock.mount(tester);
      await _tap(tester, 'sale-add-DEMO-PIN');
      await _type(tester, 'DEMO-PIN', '3');
      stock.pin = 1;
      stock.sales.unavailable = {'DEMO-PIN'};
      await _tap(tester, 'shell-more');
      await tester.tap(find.text('Actualizar catálogo'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<IconButton>(_key('sale-line-increment-DEMO-PIN'))
            .onPressed,
        isNull,
      );
      expect(stock.sales.quotedCarts.last.lines.single.quantity, '3');
      await _tap(tester, 'sale-cart-button');
      expect(find.text('3 piece'), findsOneWidget);
      expect(find.text('Sin existencias suficientes'), findsOneWidget);
      expect(
        tester.widget<FilledButton>(_key('sale-charge')).onPressed,
        isNull,
      );
      await _tap(tester, 'sale-line-decrement-DEMO-PIN');
      expect(find.text('Solo hay 1 piece en existencia.'), findsOneWidget);
      expect(stock.sales.quotedCarts.last.lines.single.quantity, '3');
    },
  );

  testWidgets(
    'server quote still flags shortages despite sufficient loaded stock and blocks charging',
    (tester) async {
      final stock = _StockCatalog();
      stock.sales.unavailable = {'DEMO-PIN'};
      await stock.mount(tester);
      await _tap(tester, 'sale-add-DEMO-PIN');
      await _tap(tester, 'sale-cart-button');
      expect(find.text('Sin existencias suficientes'), findsOneWidget);
      expect(
        tester.widget<FilledButton>(_key('sale-charge')).onPressed,
        isNull,
      );
      expect(stock.sales.submittedDrafts, isEmpty);
    },
  );
}
