import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/app/panel_layout.dart';
import 'package:lda_inventory/sales/sale_cart_controller.dart';
import 'package:lda_inventory/sales/sale_cart_panel.dart';
import 'package:lda_inventory/sales/sale_draft.dart';
import 'package:lda_inventory/sales/sale_format.dart';
import 'package:lda_inventory/sales/sale_receipt_view.dart';

import 'sale_ui_fixtures.dart';

void _add(SaleCartController controller, String quantity) =>
    controller.saveEntry(
      productId: ribbonProduct.internalCode,
      name: ribbonProduct.name,
      quantitySpec: ribbonProduct.quantitySpec,
      quantity: quantity,
    );

Future<void> _pump(
  WidgetTester tester,
  Widget body,
  double width,
  double scale,
) async {
  await tester.binding.setSurfaceSize(Size(width, 900));
  await tester.pumpWidget(
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(
          size: Size(width, 900),
          textScaler: TextScaler.linear(scale),
          disableAnimations: true,
        ),
        child: Scaffold(body: body),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Finder _rail(WidgetTester tester) {
  final layout = tester.widget<PanelLayout>(find.byType(PanelLayout));
  return find.byWidget(layout.context!);
}

void main() {
  for (final double width in <double>[400, 601, 1200]) {
    for (final double scale in <double>[1, 2]) {
      for (final bool receiptPanel in <bool>[false, true]) {
        testWidgets(
          '${receiptPanel ? 'receipt' : 'cart'} $width scale $scale preserves compact body or shows real context',
          (tester) async {
            addTearDown(() => tester.binding.setSurfaceSize(null));
            final sales = FakeSaleCheckout();
            final controller = SaleCartController(checkout: sales.checkout);
            addTearDown(controller.dispose);
            _add(controller, '1');
            controller.setInvoiceRequested(true);
            await tester.pump();
            await controller.charge();
            final SaleReceipt receipt = controller.lastReceipt!;
            // A fresh controller keeps the cart editable after obtaining a receipt.
            final cartController = SaleCartController(
              checkout: FakeSaleCheckout().checkout,
            );
            addTearDown(cartController.dispose);
            _add(cartController, '1');
            cartController.setInvoiceRequested(true);
            final Widget panel = receiptPanel
                ? SaleReceiptView(receipt: receipt, onNewSale: () {})
                : SaleCartPanel(controller: cartController, onClose: () {});
            await _pump(tester, panel, width, scale);
            expect(tester.takeException(), isNull);
            expect(find.byType(PanelLayout), findsOneWidget);
            final layout = tester.widget<PanelLayout>(find.byType(PanelLayout));
            final rail = _rail(tester);
            if (width < panelWideBreakpoint) {
              expect(rail, findsNothing);
              final beforeTexts = tester
                  .widgetList<Text>(find.byType(Text))
                  .map((w) => w.data)
                  .toList();
              final scroll = find.byType(SingleChildScrollView);
              expect(scroll, findsOneWidget);
              final beforeRect = tester.getRect(scroll);
              // The compact scaffold renders the exact original primary, with
              // identical text, padding, width, alignment and scroll geometry.
              await _pump(tester, layout.primary, width, scale);
              expect(
                tester
                    .widgetList<Text>(find.byType(Text))
                    .map((w) => w.data)
                    .toList(),
                beforeTexts,
              );
              expect(
                tester.getRect(find.byType(SingleChildScrollView)),
                beforeRect,
              );
            } else {
              expect(rail, findsOneWidget);
              expect(
                tester.getRect(find.byWidget(layout.primary)).right,
                lessThan(tester.getRect(rail).left),
              );
              Finder text(String value) =>
                  find.descendant(of: rail, matching: find.text(value));
              expect(text('1 producto'), findsOneWidget);
              expect(text('Total'), findsOneWidget);
              expect(text('11.60 MXN'), findsOneWidget);
              if (receiptPanel) {
                expect(text(receipt.folio), findsOneWidget);
                expect(text('NTE'), findsOneWidget);
                expect(
                  text(formatSaleDateTime(receipt.createdAt.toLocal())),
                  findsOneWidget,
                );
                expect(text('Efectivo'), findsOneWidget);
                expect(
                  find.descendant(
                    of: rail,
                    matching: find.byType(SaleReceiptQr),
                  ),
                  findsNothing,
                );
                expect(find.byType(SaleReceiptQr), findsOneWidget);
                expect(
                  find.byKey(const ValueKey('sale-receipt-folio')),
                  findsOneWidget,
                );
              } else {
                expect(text('Ribbon'), findsOneWidget);
                expect(text('Subtotal'), findsOneWidget);
                expect(text('10.00 MXN'), findsWidgets);
                expect(text('IVA adicional'), findsOneWidget);
                expect(text('1.60 MXN'), findsOneWidget);
              }
            }
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  }

  testWidgets('cart context follows mutations and never keeps stale totals', (
    tester,
  ) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final sales = FakeSaleCheckout();
    final controller = SaleCartController(checkout: sales.checkout);
    addTearDown(controller.dispose);
    _add(controller, '1');
    await _pump(
      tester,
      SaleCartPanel(controller: controller, onClose: () {}),
      1200,
      1,
    );
    final rail = _rail(tester);
    expect(
      find.descendant(of: rail, matching: find.text('10.00 MXN')),
      findsWidgets,
    );
    sales.holdQuotes = true;
    _add(controller, '2');
    await tester.pump();
    expect(
      find.descendant(of: _rail(tester), matching: find.text('10.00 MXN')),
      findsNothing,
    );
    expect(
      find.descendant(of: _rail(tester), matching: find.text('Calculando…')),
      findsWidgets,
    );
    sales.heldQuotes.single.complete(sales.quoteNow(controller.cart));
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: _rail(tester), matching: find.text('20.00 MXN')),
      findsWidgets,
    );
    controller.remove(ribbonProduct.internalCode);
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: _rail(tester), matching: find.text('0 productos')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: _rail(tester), matching: find.text('20.00 MXN')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });
}
