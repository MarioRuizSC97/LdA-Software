import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/sales/sale_cart_controller.dart';
import 'package:lda_inventory/sales/sale_cart_panel.dart';

import 'sale_ui_fixtures.dart';

void main() {
  for (final width in <double>[390, 800]) {
    for (final scale in <double>[1, 1.5]) {
      testWidgets('add/stepper footprint at width $width, text scale $scale', (
        tester,
      ) async {
        final controller = SaleCartController(
          checkout: FakeSaleCheckout().checkout,
        );
        addTearDown(controller.dispose);
        await tester.pumpWidget(
          MaterialApp(
            home: MediaQuery(
              data: MediaQueryData(
                size: Size(width, 800),
                textScaler: TextScaler.linear(scale),
              ),
              child: Scaffold(
                body: Center(
                  child: SizedBox(
                    width: 180,
                    child: SaleAddControl(
                      controller: controller,
                      product: pinProduct,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final add = find.byKey(const ValueKey<String>('sale-add-DEMO-PIN'));
        // Compare painted surfaces, not just the button's invisible tap target.
        final addSurface = find.descendant(
          of: add,
          matching: find.byType(Material),
        );
        final addSize = tester.getSize(addSurface);
        final hostSize = tester.getSize(find.byType(SaleAddControl));
        await tester.tap(add);
        await tester.pumpAndSettle();
        final stepperSurface = find
            .descendant(
              of: find.byType(SaleLineStepper),
              matching: find.byType(DecoratedBox),
            )
            .first;
        final stepperSize = tester.getSize(stepperSurface);
        expect(addSize, Size(176, 48 * scale));
        expect(
          stepperSize.height,
          addSize.height,
          reason: 'Painted surfaces: add=$addSize, stepper=$stepperSize',
        );
        expect(stepperSize.width, addSize.width);
        expect(tester.getSize(find.byType(SaleAddControl)), hostSize);
        await tester.tap(
          find.byKey(const ValueKey<String>('sale-line-remove-DEMO-PIN')),
        );
        await tester.pumpAndSettle();
        expect(tester.getSize(addSurface), addSize);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
