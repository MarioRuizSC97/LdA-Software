import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/sales/sale_cart.dart';
import 'package:lda_inventory/sales/sale_draft.dart';
import 'package:lda_inventory/sales/sale_quote.dart';
import 'package:lda_inventory/sales/sale_receipt_view.dart';

import 'sale_fixtures.dart';

SaleReceipt _receipt() {
  final SaleDraft draft = SaleDraft.fromQuote(
    quote: SaleQuote.fromCallable(quoteResponse(), cart: invoicedCart()),
    branchId: saleBranchId,
    paymentMethod: SalePaymentMethod.card,
    createKey: () => saleKey,
  );
  return SaleReceipt.fromCallable(submitResponse(), draft: draft);
}

TextStyle _effectiveStyle(WidgetTester tester, String text) {
  // The rail repeats the total; preserve primary receipt styling checks.
  final Finder finder = find.descendant(
    of: find.byType(SingleChildScrollView).first,
    matching: find.text(text),
  );
  final Text widget = tester.widget<Text>(finder);
  return DefaultTextStyle.of(tester.element(finder)).style.merge(widget.style);
}

void main() {
  for (final Brightness brightness in Brightness.values) {
    for (final bool reducedMotion in <bool>[false, true]) {
      final String mode = '${brightness.name}, reduced motion: $reducedMotion';

      Future<void> pumpReceipt(WidgetTester tester, VoidCallback onNewSale) =>
          tester.pumpWidget(
            MaterialApp(
              theme: ThemeData(brightness: brightness),
              home: MediaQuery(
                data: MediaQueryData(disableAnimations: reducedMotion),
                child: Scaffold(
                  body: SaleReceiptView(
                    receipt: _receipt(),
                    onNewSale: onNewSale,
                  ),
                ),
              ),
            ),
          );

      testWidgets('Nueva venta is tonal and keeps its action ($mode)', (
        WidgetTester tester,
      ) async {
        int calls = 0;
        await pumpReceipt(tester, () => calls += 1);
        final Finder action = find.byKey(
          const ValueKey<String>('sale-receipt-new'),
        );
        expect(tester.widget(action), isA<FilledButton>());
        expect(
          find.descendant(of: action, matching: find.text('Nueva venta')),
          findsOneWidget,
        );
        final FilledButton button = tester.widget<FilledButton>(action);
        final BuildContext context = tester.element(action);
        final ColorScheme colors = Theme.of(context).colorScheme;
        final ButtonStyle style = button.defaultStyleOf(context);
        expect(
          style.backgroundColor?.resolve(<WidgetState>{}),
          colors.secondaryContainer,
        );
        expect(
          style.foregroundColor?.resolve(<WidgetState>{}),
          colors.onSecondaryContainer,
        );
        await tester.ensureVisible(action);
        await tester.pumpAndSettle();
        await tester.tap(action);
        expect(calls, 1);
        expect(tester.takeException(), isNull);
      });

      testWidgets(
        'total matches catalog emphasis; subtotal is secondary ($mode)',
        (WidgetTester tester) async {
          await pumpReceipt(tester, () {});
          final BuildContext context = tester.element(
            find.byType(SaleReceiptView),
          );
          final TextStyle catalogPrice = Theme.of(context).textTheme.titleLarge!
              .copyWith(fontWeight: FontWeight.w700);
          final TextStyle total = _effectiveStyle(tester, '36.50 MXN');
          final TextStyle subtotal = _effectiveStyle(tester, '32.50 MXN');
          expect(total.fontWeight, FontWeight.w700);
          expect(total.fontWeight, catalogPrice.fontWeight);
          expect(total.fontSize, catalogPrice.fontSize);
          expect(subtotal.fontWeight!.value, lessThan(total.fontWeight!.value));
          expect(subtotal.fontSize, lessThan(total.fontSize!));
          final TextStyle totalLabel = _effectiveStyle(tester, 'Total');
          expect(totalLabel.fontWeight, total.fontWeight);
          expect(totalLabel.fontSize, total.fontSize);
        },
      );
    }
  }
}
