import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/corrections/correction_receipt.dart';
import 'package:lda_inventory/corrections/correction_replacement_receipt_view.dart';

import 'correction_fixtures.dart';
import 'correction_ui_fixtures.dart';

Finder _key(String value) => find.byKey(ValueKey<String>(value));

/// Pumps the receipt on a tall surface, so the whole list stays built, then
/// taps both buttons and returns how often each fired.
Future<(int, int)> _pump(
  WidgetTester tester,
  Widget Function(VoidCallback onBack, VoidCallback onSearch) build,
  String prefix,
) async {
  tester.view.physicalSize = const Size(800, 4000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  int backs = 0;
  int searches = 0;
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: build(() => backs += 1, () => searches += 1)),
    ),
  );
  await tester.pumpAndSettle();
  for (final String key in <String>['$prefix-back', '$prefix-new-search']) {
    await tester.tap(_key(key));
    await tester.pumpAndSettle();
  }
  return (backs, searches);
}

void _expectTexts(List<String> texts) {
  for (final String text in texts) {
    expect(find.text(text), findsOneWidget, reason: text);
  }
}

void main() {
  testWidgets('a replacement receipt shows lines at no charge', (
    WidgetTester tester,
  ) async {
    final SaleReplacementReceipt receipt = SaleReplacementReceipt.fromCallable(
      replacementResponse(),
      draft: replacementDraft(),
    );
    final (int backs, int searches) = await _pump(
      tester,
      (VoidCallback back, VoidCallback search) =>
          CorrectionReplacementReceiptView(
            receipt: receipt,
            sale: lookupSale(),
            productNames: catalogNames,
            onBackToSale: back,
            onNewSearch: search,
          ),
      'replacement-receipt',
    );
    _expectTexts(<String>[
      'Reemplazo registrado',
      'Venta NTE-3F2A-9C1B',
      'Motivo: Defecto de fábrica',
      'Pin',
      'Cantidad: 2 piece',
      'Sin costo',
    ]);
    expect(find.text('Reemplazo repetido (ya registrado)'), findsNothing);
    expect((backs, searches), (1, 1));
  });

  testWidgets('a replayed replacement says so', (WidgetTester tester) async {
    final SaleReplacementReceipt receipt = SaleReplacementReceipt.fromCallable(
      replacementResponse(replayed: true),
      draft: replacementDraft(),
    );
    await _pump(
      tester,
      (VoidCallback back, VoidCallback search) =>
          CorrectionReplacementReceiptView(
            receipt: receipt,
            sale: lookupSale(),
            productNames: catalogNames,
            onBackToSale: back,
            onNewSearch: search,
          ),
      'replacement-receipt',
    );
    expect(find.text('Reemplazo repetido (ya registrado)'), findsOneWidget);
  });
}
