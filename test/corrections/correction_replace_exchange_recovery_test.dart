import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/corrections/correction_draft.dart';
import 'package:lda_inventory/corrections/correction_exchange_form.dart';
import 'package:lda_inventory/corrections/correction_lookup_view.dart';
import 'package:lda_inventory/corrections/correction_receipt.dart';
import 'package:lda_inventory/firebase/emulator_sale_gateway.dart';

import '../sales/sale_fixtures.dart';
import 'correction_fixtures.dart';
import 'correction_ui_fixtures.dart';

// Replacements and exchanges follow the return's receipt recovery: whatever
// a submit's outcome after its form closed, reopening corrections shows the
// committed receipt, or the locked same-key draft, never a lost correction.

Finder _key(String value) => find.byKey(ValueKey<String>(value));

Future<void> _pumpLookup(WidgetTester tester, FakeCorrections backend) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: CorrectionLookupView(
          corrections: backend.corrections,
          productNames: catalogNames,
          products: exchangeCatalog,
          onClose: () {},
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _closeLookup(WidgetTester tester) async {
  await tester.pumpWidget(const MaterialApp(home: SizedBox()));
  await tester.pump();
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> _enter(WidgetTester tester, String key, String text) async {
  await tester.ensureVisible(_key(key));
  await tester.enterText(_key(key), text);
  await tester.pump();
}

Future<void> _openSale(WidgetTester tester) async {
  await tester.enterText(_key('correction-folio'), 'NTE-3F2A-9C1B');
  await _tap(tester, _key('correction-search'));
}

/// Opens the replacement form for the default sale and confirms two pins.
Future<void> _confirmReplacement(
  WidgetTester tester,
  FakeCorrections backend,
  Object result,
) async {
  final int sent = backend.replacementSubmits.length;
  backend.replacementResults.add(result);
  await _openSale(tester);
  await _tap(tester, _key('correction-action-replace'));
  await _tap(tester, _key('replacement-line-select-1'));
  await _enter(tester, 'replacement-line-quantity-1', '2');
  await tester.ensureVisible(_key('replacement-confirm'));
  await tester.pumpAndSettle();
  await tester.tap(_key('replacement-confirm'));
  await tester.pump();
  expect(backend.replacementSubmits, hasLength(sent + 1));
}

/// Opens the exchange form, returns one pin for two tapes and confirms.
Future<void> _confirmExchange(
  WidgetTester tester,
  FakeCorrections backend,
  Object result,
) async {
  final int sent = backend.exchangeSubmits.length;
  backend.exchangeResults.add(result);
  await _openSale(tester);
  await _tap(tester, _key('correction-action-exchange'));
  await _tap(tester, _key('exchange-line-select-1'));
  await _enter(tester, 'exchange-line-quantity-1', '1');
  await _tap(tester, _key('exchange-reason-wrong-product'));
  await _tap(tester, _key('exchange-product-add-DEMO-TAPE'));
  await _enter(tester, 'exchange-new-quantity-DEMO-TAPE', '2');
  await tester.pump(exchangePreviewDelay);
  await tester.pumpAndSettle();
  await tester.ensureVisible(_key('exchange-confirm'));
  await tester.pumpAndSettle();
  await tester.tap(_key('exchange-confirm'));
  await tester.pump();
  expect(backend.exchangeSubmits, hasLength(sent + 1));
}

void main() {
  testWidgets('a replacement shows its receipt, then the refetched sale', (
    WidgetTester tester,
  ) async {
    final FakeCorrections backend = FakeCorrections();
    await _pumpLookup(tester, backend);
    await _confirmReplacement(tester, backend, answerNormally);
    await tester.pumpAndSettle();
    expect(_key('replacement-receipt'), findsOneWidget);
    expect(find.text('Reemplazo registrado'), findsOneWidget);

    await _tap(tester, _key('replacement-receipt-back'));
    final SaleReplacementDraft draft = backend.replacementSubmits.single;
    expect(backend.finds.last, <String, Object?>{'saleId': draft.saleId});
    expect(_key('correction-detail'), findsOneWidget);
    expect(backend.acknowledged.single, isA<SaleReplacementReceipt>());
    expect(backend.completed, isNull);
  });

  testWidgets('an exchange shows its receipt, then a new search', (
    WidgetTester tester,
  ) async {
    final FakeCorrections backend = FakeCorrections();
    await _pumpLookup(tester, backend);
    await _confirmExchange(tester, backend, answerNormally);
    await tester.pumpAndSettle();
    expect(_key('exchange-receipt'), findsOneWidget);
    expect(find.text('El cliente pagó: 20.70 MXN'), findsOneWidget);

    await _tap(tester, _key('exchange-receipt-back'));
    expect(backend.finds.last, <String, Object?>{'saleId': saleKey});
    expect(_key('correction-detail'), findsOneWidget);
    expect(backend.acknowledged.single, isA<SaleExchangeReceipt>());
  });

  for (final String kind in <String>['replacement', 'exchange']) {
    Future<void> confirm(
      WidgetTester tester,
      FakeCorrections backend,
      Object result,
    ) => kind == 'replacement'
        ? _confirmReplacement(tester, backend, result)
        : _confirmExchange(tester, backend, result);

    SaleCorrectionDraft sent(FakeCorrections backend) => kind == 'replacement'
        ? backend.replacementSubmits.last
        : backend.exchangeSubmits.last;

    SaleCorrectionReceipt receiptFor(SaleCorrectionDraft draft) =>
        switch (draft) {
          final SaleReplacementDraft d => SaleReplacementReceipt.fromCallable(
            replacementResponseFor(d),
            draft: d,
          ),
          final SaleExchangeDraft d => SaleExchangeReceipt.fromCallable(
            exchangeResponseFor(d),
            draft: d,
          ),
          final SaleReturnDraft d => SaleReturnReceipt.fromCallable(
            returnResponseFor(d),
            draft: d,
          ),
        };

    testWidgets('a $kind committed after its form closed shows its receipt', (
      WidgetTester tester,
    ) async {
      final FakeCorrections backend = FakeCorrections();
      final Completer<Object?> gate = Completer<Object?>();
      await _pumpLookup(tester, backend);
      await confirm(tester, backend, gate);
      final SaleCorrectionDraft draft = sent(backend);
      await _closeLookup(tester);
      gate.complete(receiptFor(draft));
      await tester.pump();

      await _pumpLookup(tester, backend);
      expect(_key('$kind-receipt'), findsOneWidget);
      expect(_key('$kind-form'), findsNothing);

      // Closing without leaving the receipt keeps it.
      await _closeLookup(tester);
      await _pumpLookup(tester, backend);
      expect(_key('$kind-receipt'), findsOneWidget);

      await _tap(tester, _key('$kind-receipt-new-search'));
      expect(backend.acknowledged, hasLength(1));
      await _closeLookup(tester);
      await _pumpLookup(tester, backend);
      expect(_key('$kind-receipt'), findsNothing);
      expect(_key('correction-folio'), findsOneWidget);
    });

    testWidgets('an uncertain $kind after its form closed reopens locked', (
      WidgetTester tester,
    ) async {
      final FakeCorrections backend = FakeCorrections();
      await _pumpLookup(tester, backend);
      final Completer<Object?> gate = Completer<Object?>();
      await confirm(tester, backend, gate);
      final SaleCorrectionDraft draft = sent(backend);
      await _closeLookup(tester);
      gate.completeError(const SaleUncertainException());
      await tester.pump();

      await _pumpLookup(tester, backend);
      expect(_key('$kind-form'), findsOneWidget);
      expect(_key('$kind-retry'), findsOneWidget);
      expect(_key('$kind-confirm'), findsNothing);

      (kind == 'replacement'
              ? backend.replacementResults
              : backend.exchangeResults)
          .add(answerReplayed);
      await _tap(tester, _key('$kind-retry'));
      expect(sent(backend), same(draft));
      expect(_key('$kind-receipt'), findsOneWidget);
      expect(find.textContaining('repetido'), findsOneWidget);
    });

    testWidgets('a rejected $kind after its form closed leaves nothing', (
      WidgetTester tester,
    ) async {
      final FakeCorrections backend = FakeCorrections();
      await _pumpLookup(tester, backend);
      final Completer<Object?> gate = Completer<Object?>();
      await confirm(tester, backend, gate);
      await _closeLookup(tester);
      gate.completeError(
        const SaleRejectedException(
          code: 'failed-precondition',
          message: 'insufficient stock',
        ),
      );
      await tester.pump();

      await _pumpLookup(tester, backend);
      expect(_key('correction-folio'), findsOneWidget);
      expect(_key('$kind-form'), findsNothing);
      expect(backend.unresolved, isNull);
      expect(backend.completed, isNull);
    });
  }

  testWidgets('a stored unresolved replacement reopens its form', (
    WidgetTester tester,
  ) async {
    final FakeCorrections backend = FakeCorrections(
      unresolved: replacementDraft(),
    )..replacementResults.add(answerReplayed);
    await _pumpLookup(tester, backend);
    expect(_key('replacement-form'), findsOneWidget);
    await _tap(tester, _key('replacement-retry'));
    expect(backend.replacementSubmits.single.idempotencyKey, replacementKey);
    expect(_key('replacement-receipt'), findsOneWidget);
    await _tap(tester, _key('replacement-receipt-back'));
    expect(backend.finds.single, <String, Object?>{'saleId': saleKey});
  });

  testWidgets('a stored unresolved exchange reopens its form', (
    WidgetTester tester,
  ) async {
    final FakeCorrections backend = FakeCorrections(unresolved: exchangeDraft())
      ..exchangeResults.add(answerReplayed);
    await _pumpLookup(tester, backend);
    expect(_key('exchange-form'), findsOneWidget);
    await _tap(tester, _key('exchange-retry'));
    expect(backend.exchangeSubmits.single.idempotencyKey, exchangeKey);
    expect(_key('exchange-receipt'), findsOneWidget);
  });

  testWidgets('a stored committed exchange shows its receipt first', (
    WidgetTester tester,
  ) async {
    final SaleExchangeDraft draft = exchangeDraft();
    final FakeCorrections backend = FakeCorrections()
      ..completed = CompletedCorrection.of(
        draft,
        SaleExchangeReceipt.fromCallable(exchangeResponse(), draft: draft),
      );
    await _pumpLookup(tester, backend);
    expect(_key('exchange-receipt'), findsOneWidget);
    expect(backend.exchangeSubmits, isEmpty);
  });
}
