import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/corrections/correction_draft.dart';
import 'package:lda_inventory/corrections/correction_receipt.dart';
import 'package:lda_inventory/corrections/correction_return_receipt_view.dart';
import 'package:lda_inventory/corrections/correction_sale.dart';

import '../sales/sale_fixtures.dart';
import 'correction_fixtures.dart';

const Map<String, String> _names = <String, String>{'DEMO-RIBBON': 'Ribbon'};

Finder _key(String value) => find.byKey(ValueKey<String>(value));

Future<(int, int)> _pump(
  WidgetTester tester,
  SaleReturnReceipt receipt,
  CorrectableSale sale,
) async {
  int backs = 0;
  int searches = 0;
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: CorrectionReturnReceiptView(
          receipt: receipt,
          sale: sale,
          productNames: _names,
          onBackToSale: () => backs += 1,
          onNewSearch: () => searches += 1,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  final Finder back = _key('return-receipt-back');
  await tester.ensureVisible(back);
  await tester.tap(back);
  await tester.pumpAndSettle();
  final Finder search = _key('return-receipt-new-search');
  await tester.ensureVisible(search);
  await tester.tap(search);
  await tester.pumpAndSettle();
  return (backs, searches);
}

void _expectTexts(Finder scope, List<String> texts) {
  for (final String text in texts) {
    expect(
      find.descendant(of: scope, matching: find.text(text)),
      findsOneWidget,
      reason: text,
    );
  }
}

void main() {
  testWidgets('an invoiced return shows lines, IVA, refund and credit note', (
    WidgetTester tester,
  ) async {
    final SaleReturnReceipt receipt = SaleReturnReceipt.fromCallable(
      returnResponse(),
      draft: returnDraft(),
    );
    final (int backs, int searches) = await _pump(
      tester,
      receipt,
      lookupSale(),
    );
    final Finder view = _key('return-receipt');
    _expectTexts(view, <String>[
      'Devolución registrada',
      'Venta NTE-3F2A-9C1B',
      'Motivo: Cambio de opinión',
      'IVA reembolsado: 1.60 MXN',
      'Total reembolsado: 14.10 MXN',
      'Se reembolsa por: Tarjeta',
      'Venta con factura: el administrador emitirá la nota de crédito',
    ]);
    _expectTexts(_key('return-receipt-line-0'), <String>[
      'Ribbon',
      'Cantidad: 1.00 meter',
      'Estado: En buen estado',
      'Reembolso: 11.60 MXN',
    ]);
    _expectTexts(_key('return-receipt-line-1'), <String>[
      'DEMO-PIN',
      'Cantidad: 1 piece',
      'Estado: Defecto de fábrica',
      'Reembolso: 2.50 MXN',
    ]);
    expect(find.text('Devolución repetida (ya registrada)'), findsNothing);
    // No server time exists, so no date or time is shown.
    expect(find.textContaining('Fecha'), findsNothing);
    expect(find.textContaining(' de 20'), findsNothing);
    expect((backs, searches), (1, 1));
  });

  testWidgets('an uninvoiced replay says so and mentions no credit note', (
    WidgetTester tester,
  ) async {
    final SaleReturnDraft draft = SaleReturnDraft.create(
      sale: uninvoicedSale(),
      branchId: saleBranchId,
      reason: CorrectionReason.factoryDefect,
      lines: const <ReturnLineInput>[
        ReturnLineInput(
          lineIndex: 0,
          quantity: '3',
          condition: ReturnCondition.factoryDefect,
        ),
      ],
      createKey: () => returnKey,
    );
    final SaleReturnReceipt receipt = SaleReturnReceipt.fromCallable(
      returnResponseFor(draft, replayed: true),
      draft: draft,
    );
    await _pump(tester, receipt, uninvoicedSale());
    _expectTexts(_key('return-receipt'), <String>[
      'Devolución registrada',
      'Devolución repetida (ya registrada)',
      'Venta NTE-4B5C-6D7E',
      'Motivo: Defecto de fábrica',
      'Total reembolsado: 7.50 MXN',
      'Se reembolsa por: Efectivo',
    ]);
    expect(find.textContaining('IVA'), findsNothing);
    expect(find.textContaining('nota de crédito'), findsNothing);
  });
}
