import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/corrections/correction_exchange_receipt_view.dart';
import 'package:lda_inventory/corrections/correction_receipt.dart';
import 'package:lda_inventory/corrections/correction_replacement_receipt_view.dart';
import 'package:lda_inventory/corrections/correction_return_receipt_view.dart';

import 'correction_fixtures.dart';
import 'correction_ui_fixtures.dart';

Future<void> _pump(WidgetTester tester, Widget view) async {
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: view)));
  await tester.pumpAndSettle();
}

void main() {
  for (final (Size size, double scale) in responsiveViewports) {
    final String at = '${size.width.toInt()}px at text scale $scale';

    testWidgets('a return receipt fits $at', (WidgetTester tester) async {
      useViewport(tester, size, scale);
      await _pump(
        tester,
        CorrectionReturnReceiptView(
          receipt: SaleReturnReceipt.fromCallable(
            returnResponse(),
            draft: returnDraft(),
          ),
          sale: lookupSale(),
          productNames: catalogNames,
          onBackToSale: () {},
          onNewSearch: () {},
        ),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('a replacement receipt fits $at', (WidgetTester tester) async {
      useViewport(tester, size, scale);
      await _pump(
        tester,
        CorrectionReplacementReceiptView(
          receipt: SaleReplacementReceipt.fromCallable(
            replacementResponse(),
            draft: replacementDraft(),
          ),
          sale: lookupSale(),
          productNames: catalogNames,
          onBackToSale: () {},
          onNewSearch: () {},
        ),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('an exchange receipt fits $at', (WidgetTester tester) async {
      useViewport(tester, size, scale);
      await _pump(
        tester,
        CorrectionExchangeReceiptView(
          receipt: SaleExchangeReceipt.fromCallable(
            exchangeResponse(),
            draft: exchangeDraft(),
          ),
          sale: lookupSale(),
          productNames: catalogNames,
          onBackToSale: () {},
          onNewSearch: () {},
        ),
      );
      expect(tester.takeException(), isNull);
    });
  }
}
