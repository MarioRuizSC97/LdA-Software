import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/corrections/correction_draft.dart';
import 'package:lda_inventory/corrections/correction_exchange_receipt_view.dart';
import 'package:lda_inventory/corrections/correction_receipt.dart';
import 'package:lda_inventory/corrections/correction_replacement_receipt_view.dart';
import 'package:lda_inventory/sales/sale_cart.dart';

import '../sales/sale_fixtures.dart';
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

  testWidgets('a paid, invoiced exchange shows both sides and the payment', (
    WidgetTester tester,
  ) async {
    final SaleExchangeReceipt receipt = SaleExchangeReceipt.fromCallable(
      exchangeResponse(),
      draft: exchangeDraft(),
    );
    final (int backs, int searches) = await _pump(
      tester,
      (VoidCallback back, VoidCallback search) => CorrectionExchangeReceiptView(
        receipt: receipt,
        sale: lookupSale(),
        productNames: catalogNames,
        onBackToSale: back,
        onNewSearch: search,
      ),
      'exchange-receipt',
    );
    _expectTexts(<String>[
      'Cambio registrado',
      'Venta NTE-3F2A-9C1B',
      'Motivo: Producto equivocado',
      'Productos devueltos',
      'Pin',
      'Cantidad: 1 piece',
      'Estado: En buen estado',
      'Valor: 2.50 MXN',
      'Valor devuelto: 2.50 MXN',
      'Productos nuevos',
      'Tape',
      'Cantidad: 2 piece',
      'Importe: 23.20 MXN',
      'IVA de productos nuevos: 3.20 MXN',
      'Total de productos nuevos: 23.20 MXN',
      'El cliente pagó: 20.70 MXN',
      'Método de pago: Efectivo',
      'Venta con factura: el administrador gestionará el ajuste de la '
          'factura',
    ]);
    expect(find.text('Cambio repetido (ya registrado)'), findsNothing);
    expect((backs, searches), (1, 1));
  });

  testWidgets('a replayed refund exchange shows the refund method', (
    WidgetTester tester,
  ) async {
    final SaleExchangeDraft draft = SaleExchangeDraft.create(
      sale: uninvoicedSale(),
      branchId: saleBranchId,
      reason: CorrectionReason.factoryDefect,
      returnLines: const <ReturnLineInput>[
        ReturnLineInput(
          lineIndex: 0,
          quantity: '2',
          condition: ReturnCondition.factoryDefect,
        ),
      ],
      newItems: SaleCart.empty().add(
        SaleCartLine(
          productId: 'DEMO-CORD',
          name: 'Cord',
          quantitySpec: cordProduct.quantitySpec,
          quantity: '1',
        ),
      ),
      createKey: () => exchangeKey,
    );
    final SaleExchangeReceipt receipt = SaleExchangeReceipt.fromCallable(
      exchangeResponseFor(draft, replayed: true),
      draft: draft,
    );
    await _pump(
      tester,
      (VoidCallback back, VoidCallback search) => CorrectionExchangeReceiptView(
        receipt: receipt,
        sale: uninvoicedSale(),
        productNames: catalogNames,
        onBackToSale: back,
        onNewSearch: search,
      ),
      'exchange-receipt',
    );
    _expectTexts(<String>[
      'Cambio repetido (ya registrado)',
      'Estado: Defecto de fábrica',
      // 5.00 returned for 0.40: 4.60 back in cash.
      'Se reembolsó: 4.60 MXN por Efectivo',
    ]);
    expect(find.textContaining('factura'), findsNothing);
    expect(find.textContaining('IVA'), findsNothing);
  });
}
