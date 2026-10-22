import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/sales/sale_cart.dart';
import 'package:lda_inventory/sales/sale_draft.dart';
import 'package:lda_inventory/sales/sale_format.dart';
import 'package:lda_inventory/sales/sale_quote.dart';
import 'package:lda_inventory/sales/sale_receipt_view.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'sale_fixtures.dart';

SaleReceipt _receipt({
  bool replayed = false,
  bool invoiced = true,
  SalePaymentMethod method = SalePaymentMethod.card,
}) {
  final SaleCart cart = invoiced
      ? invoicedCart()
      : SaleCart.empty().add(pinLine);
  final Map<String, Object?> calculation = invoiced
      ? invoicedCalculation()
      : uninvoicedPinCalculation();
  final int total = calculation['totalCentavos']! as int;
  final SaleDraft draft = SaleDraft.fromQuote(
    quote: SaleQuote.fromCallable(<String, Object?>{
      'calculation': calculation,
      'totalCentavos': total,
      'lines': <Object?>[
        for (final SaleCartLine line in cart.lines)
          <String, Object?>{'productId': line.productId, 'available': true},
      ],
    }, cart: cart),
    branchId: saleBranchId,
    paymentMethod: method,
    createKey: () => saleKey,
  );
  return SaleReceipt.fromCallable(<String, Object?>{
    'receipt': <String, Object?>{
      ...receiptV2(method: method.wireValue, amountCentavos: total),
      'productIds': <Object?>[
        for (final SaleCartLine line in cart.lines) line.productId,
      ],
      'calculation': calculation,
    },
    'replayed': replayed,
    'createdAt': saleCreatedAtMillis,
  }, draft: draft);
}

Map<String, Object?> uninvoicedPinCalculation() {
  final Map<String, Object?> calculation = invoicedCalculation();
  final Map<String, Object?> pin = Map<String, Object?>.of(
    (calculation['lines']! as List<Object?>)[1]! as Map<String, Object?>,
  );
  return <String, Object?>{
    ...calculation,
    'invoiceRequested': false,
    'lines': <Object?>[pin],
    'baseCentavos': pin['baseCentavos'],
    'additionalIvaCentavos': 0,
    'totalCentavos': pin['totalCentavos'],
  };
}

Future<void> _pump(
  WidgetTester tester,
  SaleReceipt receipt, {
  VoidCallback? onNewSale,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SaleReceiptView(receipt: receipt, onNewSale: onNewSale ?? () {}),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Finder _key(String value) => find.byKey(ValueKey<String>(value));

// Keep original-body assertions independent of the wide metadata rail.
Finder _primaryText(String text) => find.descendant(
  of: find.byType(SingleChildScrollView).first,
  matching: find.text(text),
);

void main() {
  group('formatSaleDateTime', () {
    test('formats the local date and time in Spanish', () {
      expect(
        formatSaleDateTime(DateTime(2026, 10, 8, 19, 42)),
        '8 de octubre de 2026, 19:42',
      );
      expect(
        formatSaleDateTime(DateTime(2027, 1, 31, 9, 5)),
        '31 de enero de 2027, 09:05',
      );
      expect(
        formatSaleDateTime(DateTime(2026, 12, 1)),
        '1 de diciembre de 2026, 00:00',
      );
      const List<String> months = <String>[
        'enero',
        'febrero',
        'marzo',
        'abril',
        'mayo',
        'junio',
        'julio',
        'agosto',
        'septiembre',
        'octubre',
        'noviembre',
        'diciembre',
      ];
      for (int month = 1; month <= 12; month++) {
        expect(
          formatSaleDateTime(DateTime(2026, month, 2, 13, 7)),
          '2 de ${months[month - 1]} de 2026, 13:07',
        );
      }
    });
  });

  testWidgets('shows the folio, QR, lines, totals, payment, invoice, time '
      'and branch', (WidgetTester tester) async {
    final SaleReceipt receipt = _receipt();
    await _pump(tester, receipt);

    expect(find.text('Venta registrada'), findsOneWidget);
    expect(
      tester.widget<Text>(_key('sale-receipt-folio')).data,
      'NTE-3F2A-9C1B',
    );
    final SaleReceiptQr qr = tester.widget<SaleReceiptQr>(
      find.byType(SaleReceiptQr),
    );
    expect(qr.data, saleKey);
    expect(
      find.descendant(
        of: find.byType(SaleReceiptQr),
        matching: find.byType(QrImageView),
      ),
      findsOneWidget,
    );
    expect(find.text('Ribbon'), findsOneWidget);
    expect(find.text('2.50 meter'), findsOneWidget);
    expect(find.text('29.00 MXN'), findsOneWidget);
    expect(find.text('Pin'), findsOneWidget);
    expect(find.text('3 piece'), findsOneWidget);
    expect(find.text('7.50 MXN'), findsOneWidget);
    expect(find.text('Subtotal'), findsOneWidget);
    expect(find.text('32.50 MXN'), findsOneWidget);
    expect(find.text('IVA adicional'), findsOneWidget);
    expect(find.text('4.00 MXN'), findsOneWidget);
    expect(_primaryText('Total'), findsOneWidget);
    expect(_primaryText('36.50 MXN'), findsOneWidget);
    expect(_primaryText('Tarjeta'), findsOneWidget);
    expect(find.text('Con factura'), findsOneWidget);
    expect(
      _primaryText(formatSaleDateTime(receipt.createdAt.toLocal())),
      findsOneWidget,
    );
    expect(_primaryText('NTE'), findsOneWidget);
    expect(find.text('Venta repetida (ya registrada)'), findsNothing);
    expect(_key('sale-receipt-new'), findsOneWidget);
  });

  testWidgets('an uninvoiced cash sale hides additional IVA', (
    WidgetTester tester,
  ) async {
    await _pump(
      tester,
      _receipt(invoiced: false, method: SalePaymentMethod.cash),
    );

    expect(find.text('Sin factura'), findsOneWidget);
    expect(_primaryText('Efectivo'), findsOneWidget);
    expect(find.text('IVA adicional'), findsNothing);
    expect(find.text('Ribbon'), findsNothing);
  });

  testWidgets('a replay is labeled and transfer is shown in Spanish', (
    WidgetTester tester,
  ) async {
    await _pump(
      tester,
      _receipt(replayed: true, method: SalePaymentMethod.transfer),
    );

    expect(find.text('Venta repetida (ya registrada)'), findsOneWidget);
    expect(_primaryText('Transferencia'), findsOneWidget);
  });

  testWidgets('Nueva venta calls back once', (WidgetTester tester) async {
    int calls = 0;
    await _pump(tester, _receipt(), onNewSale: () => calls += 1);
    await tester.ensureVisible(_key('sale-receipt-new'));
    await tester.pumpAndSettle();
    await tester.tap(_key('sale-receipt-new'));
    expect(calls, 1);
  });

  testWidgets('has Spanish semantic labels', (WidgetTester tester) async {
    final SemanticsHandle semantics = tester.ensureSemantics();
    await _pump(tester, _receipt());

    expect(
      find.bySemanticsLabel(RegExp(r'^Folio NTE-3F2A-9C1B$')),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel(RegExp(r'^Código QR de la venta NTE-3F2A-9C1B$')),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel(RegExp(r'^Iniciar una nueva venta$')),
      findsOneWidget,
    );
    semantics.dispose();
  });

  testWidgets('works on a narrow screen without overflow', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await _pump(tester, _receipt(replayed: true));

    expect(tester.takeException(), isNull);
    await tester.ensureVisible(_key('sale-receipt-new'));
    await tester.pumpAndSettle();
    expect(_key('sale-receipt-new'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
