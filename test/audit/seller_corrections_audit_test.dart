import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/corrections/correction_exchange_form.dart';
import 'package:lda_inventory/corrections/correction_exchange_receipt_view.dart';
import 'package:lda_inventory/corrections/correction_lookup_view.dart';
import 'package:lda_inventory/corrections/correction_receipt.dart';
import 'package:lda_inventory/corrections/correction_replacement_form.dart';
import 'package:lda_inventory/corrections/correction_replacement_receipt_view.dart';
import 'package:lda_inventory/corrections/correction_return_form.dart';
import 'package:lda_inventory/corrections/correction_return_receipt_view.dart';
import 'package:lda_inventory/corrections/correction_sale.dart';
import 'package:lda_inventory/corrections/correction_sale_detail.dart';
import 'package:lda_inventory/firebase/emulator_sale_gateway.dart';

import '../corrections/correction_fixtures.dart';
import '../corrections/correction_ui_fixtures.dart';

Finder _key(String key) => find.byKey(ValueKey<String>(key));
Future<void> _tap(WidgetTester tester, String key) async {
  await tester.ensureVisible(_key(key));
  await tester.pumpAndSettle();
  await tester.tap(_key(key));
  await tester.pumpAndSettle();
}

Widget _view(String name, FakeCorrections backend) => switch (name) {
  'lookup' => CorrectionLookupView(corrections: backend.corrections,
    productNames: catalogNames),
  'detail' => CorrectionSaleDetail(sale: lookupSale(), productNames: catalogNames,
    onBack: () {}, onReturn: () {}, onReplace: () {}, onExchange: () {}),
  'return' => CorrectionReturnForm(sale: lookupSale(), corrections: backend.corrections,
    productNames: catalogNames, onBack: () {}, onCompleted: (_) {}),
  'replacement' => CorrectionReplacementForm(sale: lookupSale(), corrections: backend.corrections,
    productNames: catalogNames, onBack: () {}, onCompleted: (_) {}),
  'exchange' => CorrectionExchangeForm(sale: lookupSale(), corrections: backend.corrections,
    products: exchangeCatalog, productNames: catalogNames, onBack: () {}, onCompleted: (_) {}),
  'return receipt' => CorrectionReturnReceiptView(
    receipt: SaleReturnReceipt.fromCallable(returnResponse(), draft: returnDraft()),
    sale: lookupSale(), productNames: catalogNames, onBackToSale: () {}, onNewSearch: () {}),
  'replacement receipt' => CorrectionReplacementReceiptView(
    receipt: SaleReplacementReceipt.fromCallable(replacementResponse(), draft: replacementDraft()),
    sale: lookupSale(), productNames: catalogNames, onBackToSale: () {}, onNewSearch: () {}),
  'exchange receipt' => CorrectionExchangeReceiptView(
    receipt: SaleExchangeReceipt.fromCallable(exchangeResponse(), draft: exchangeDraft()),
    sale: lookupSale(), productNames: catalogNames, onBackToSale: () {}, onNewSearch: () {}),
  _ => throw ArgumentError(name),
};

Future<void> _mount(WidgetTester tester, String name, FakeCorrections backend,
    {Brightness brightness = Brightness.light}) async {
  await tester.pumpWidget(MaterialApp(theme: ThemeData(brightness: brightness),
    home: Scaffold(body: _view(name, backend))));
  await tester.pumpAndSettle();
}

Future<void> _fill(WidgetTester tester, String kind) async {
  await _tap(tester, '$kind-line-select-1');
  await tester.enterText(_key('$kind-line-quantity-1'), '1');
  if (kind != 'replacement') await _tap(tester, '$kind-reason-wrong-product');
  if (kind == 'exchange') {
    await _tap(tester, 'exchange-product-add-DEMO-TAPE');
    await tester.enterText(_key('exchange-new-quantity-DEMO-TAPE'), '2');
  }
  await tester.pump(const Duration(milliseconds: 450));
  await tester.pumpAndSettle();
}

void main() {
  for (final name in <String>['lookup', 'detail', 'return', 'replacement', 'exchange',
    'return receipt', 'replacement receipt', 'exchange receipt']) {
    for (final width in <double>[320, 400, 600, 1200]) {
      for (final brightness in Brightness.values) {
        testWidgets('$name ${width.toInt()}px ${brightness.name} scale 1.3', (tester) async {
          useViewport(tester, Size(width, 900), 1.3);
          await _mount(tester, name, FakeCorrections(), brightness: brightness);
          expect(tester.takeException(), isNull, reason: 'initial panel');
          if (<String>['return', 'replacement', 'exchange'].contains(name)) {
            await _fill(tester, name);
            await tester.ensureVisible(_key('$name-confirm'));
            await tester.pumpAndSettle();
            expect(tester.widget<FilledButton>(_key('$name-confirm')).onPressed, isNotNull);
          }
          await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
          // A replacement's "Sin costo para el cliente" is NOT acquisition cost.
          final private = RegExp(r'Costo de adquisición|costCentavos|purchaseCost', caseSensitive: false);
          expect(find.textContaining(private), findsNothing);
          expect(find.bySemanticsLabel(private), findsNothing);
          expect(tester.takeException(), isNull, reason: 'populated / preview panel');
        });
      }
    }
  }

  for (final kind in <String>['return', 'replacement', 'exchange']) {
    testWidgets('$kind double confirmation and uncertain retry preserve one draft', (tester) async {
      final backend = FakeCorrections();
      final firstGate = Completer<Object?>();
      final results = switch (kind) {
        'return' => backend.submitResults,
        'replacement' => backend.replacementResults,
        _ => backend.exchangeResults,
      };
      results.add(firstGate);
      await _mount(tester, kind, backend);
      await _fill(tester, kind);
      await tester.ensureVisible(_key('$kind-confirm'));
      await tester.pumpAndSettle();
      await tester.tap(_key('$kind-confirm'));
      await tester.tap(_key('$kind-confirm'));
      await tester.pump();
      final drafts = switch (kind) {
        'return' => backend.submits,
        'replacement' => backend.replacementSubmits,
        _ => backend.exchangeSubmits,
      };
      expect(drafts, hasLength(1));
      firstGate.completeError(const SaleUncertainException());
      await tester.pumpAndSettle();
      final retryGate = Completer<Object?>();
      results.add(retryGate);
      await tester.ensureVisible(_key('$kind-retry'));
      await tester.pumpAndSettle();
      await tester.tap(_key('$kind-retry'));
      await tester.tap(_key('$kind-retry'));
      await tester.pump();
      expect(drafts, hasLength(2));
      expect(drafts.last, same(drafts.first));
      expect(drafts.last.idempotencyKey, drafts.first.idempotencyKey);
      retryGate.completeError(const SaleUncertainException());
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('$kind expired window explains the 15 day limit without server text', (tester) async {
      final backend = FakeCorrections();
      final results = switch (kind) {
        'return' => backend.submitResults,
        'replacement' => backend.replacementResults,
        _ => backend.exchangeResults,
      };
      results.add(const SaleRejectedException(code: 'failed-precondition',
        reason: 'correction-window-closed', message: 'sale is outside the correction window'));
      await _mount(tester, kind, backend);
      await _fill(tester, kind);
      await _tap(tester, '$kind-confirm');
      expect(find.textContaining('15 días'), findsWidgets);
      expect(find.textContaining('sale is outside'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('$kind invalid quantity cannot be submitted or previewed as zero', (tester) async {
      final backend = FakeCorrections();
      await _mount(tester, kind, backend);
      await _fill(tester, kind);
      for (final value in <String>['0', '-1', '4', '1.5']) {
        await tester.enterText(_key('$kind-line-quantity-1'), value);
        await tester.pump(const Duration(milliseconds: 450));
        await tester.pumpAndSettle();
        expect(tester.widget<FilledButton>(_key('$kind-confirm')).onPressed, isNull,
          reason: 'invalid remaining quantity $value');
      }
      expect(backend.submits, isEmpty);
      expect(backend.replacementSubmits, isEmpty);
      expect(backend.exchangeSubmits, isEmpty);
    });
  }

  for (final kind in <String>['return', 'exchange']) {
    for (final width in <double>[320, 400, 600, 1200]) {
      for (final brightness in Brightness.values) {
        testWidgets('$kind pending and failed preview ${width.toInt()}px ${brightness.name} scale 1.3', (tester) async {
          useViewport(tester, Size(width, 900), 1.3);
          final backend = FakeCorrections();
          final returnGate = Completer<SaleReturnPreview>();
          final exchangeGate = Completer<SaleExchangePreview>();
          if (kind == 'return') {
            backend.previewResults.add(returnGate);
          } else {
            backend.exchangePreviewResults.add(exchangeGate);
          }
          await _mount(tester, kind, backend, brightness: brightness);
          await _fill(tester, kind);
          await tester.ensureVisible(_key('$kind-confirm'));
          await tester.pumpAndSettle();
          expect(find.textContaining('Calculando'), findsWidgets);
          expect(find.textContaining(RegExp(r'(Total a reembolsar|El cliente paga|Se reembolsa): 0.00 MXN')), findsNothing);
          expect(tester.widget<FilledButton>(_key('$kind-confirm')).onPressed, isNull);
          expect(tester.takeException(), isNull, reason: 'pending preview');
          if (kind == 'return') {
            returnGate.completeError(const SaleUncertainException());
          } else {
            exchangeGate.completeError(const SaleUncertainException());
          }
          await tester.pumpAndSettle();
          expect(tester.widget<FilledButton>(_key('$kind-confirm')).onPressed, isNull);
          expect(find.textContaining(RegExp(r'(Total a reembolsar|El cliente paga|Se reembolsa): 0.00 MXN')), findsNothing);
          expect(find.textContaining('Reintentar'), findsWidgets);
          expect(tester.takeException(), isNull, reason: 'failed preview');
        });
      }
    }
  }

  testWidgets('lookup double search is single-flight and hides raw exceptions', (tester) async {
    final pending = Completer<CorrectableSale>();
    final backend = FakeCorrections()..findResults.add(pending);
    await _mount(tester, 'lookup', backend);
    expect(find.textContaining('15 días'), findsWidgets);
    expect(find.text('No hay ventas recientes'), findsOneWidget);
    await tester.enterText(_key('correction-folio'), 'NTE-3F2A-9C1B');
    await tester.tap(_key('correction-search'));
    await tester.tap(_key('correction-search'));
    await tester.pump();
    expect(backend.finds, hasLength(1));
    expect(find.text('0.00 MXN'), findsNothing);
    pending.completeError(StateError('internal secret database failure'));
    await tester.pumpAndSettle();
    expect(find.textContaining('internal secret'), findsNothing);
    expect(find.text('No se pudo buscar la venta. Intenta de nuevo.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
