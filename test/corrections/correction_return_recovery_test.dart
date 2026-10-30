import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/corrections/correction_draft.dart';
import 'package:lda_inventory/corrections/correction_lookup_view.dart';
import 'package:lda_inventory/corrections/correction_receipt.dart';
import 'package:lda_inventory/corrections/correction_return_controller.dart';
import 'package:lda_inventory/firebase/emulator_sale_gateway.dart';

import 'correction_fixtures.dart';
import 'correction_ui_fixtures.dart';

// A return form can be disposed while its submit is in flight (the
// corrections view closes with the session or the page). Whatever the
// submit's outcome, reopening corrections must never hide a committed
// return: the seller sees its receipt, or the locked same-key draft whose
// retry replays to that receipt.

const Map<String, String> _names = <String, String>{'DEMO-RIBBON': 'Ribbon'};

Finder _key(String value) => find.byKey(ValueKey<String>(value));

Future<void> _pumpLookup(WidgetTester tester, FakeCorrections backend) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: CorrectionLookupView(
          corrections: backend.corrections,
          productNames: _names,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Disposes the lookup, and with it any open return form.
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

/// Searches the default sale, opens its return form, fills the pin line
/// and confirms. The submit is left pending on [pending].
Future<void> _confirmPendingReturn(
  WidgetTester tester,
  FakeCorrections backend,
  Completer<SaleReturnReceipt> pending,
) async {
  final int sent = backend.submits.length;
  backend.submitResults.add(pending);
  await tester.enterText(_key('correction-folio'), 'NTE-3F2A-9C1B');
  await _tap(tester, _key('correction-search'));
  await _tap(tester, _key('correction-action-return'));
  await _tap(tester, _key('return-line-select-1'));
  await tester.enterText(_key('return-line-quantity-1'), '1');
  await tester.pump();
  await _tap(tester, _key('return-reason-change-of-mind'));
  await tester.pump(returnPreviewDelay);
  await tester.pumpAndSettle();
  await tester.ensureVisible(_key('return-confirm'));
  await tester.pumpAndSettle();
  await tester.tap(_key('return-confirm'));
  // The submit spinner never settles, so pump once.
  await tester.pump();
  expect(backend.submits, hasLength(sent + 1));
}

SaleReturnReceipt _receiptFor(SaleReturnDraft draft) =>
    SaleReturnReceipt.fromCallable(returnResponseFor(draft), draft: draft);

void main() {
  testWidgets('a return committed after its form closed shows its receipt', (
    WidgetTester tester,
  ) async {
    final FakeCorrections backend = FakeCorrections();
    final Completer<SaleReturnReceipt> pending = Completer<SaleReturnReceipt>();
    await _pumpLookup(tester, backend);
    await _confirmPendingReturn(tester, backend, pending);
    final SaleReturnDraft draft = backend.submits.single;

    await _closeLookup(tester);
    pending.complete(_receiptFor(draft));
    await tester.pump();

    await _pumpLookup(tester, backend);
    expect(_key('return-receipt'), findsOneWidget);
    expect(_key('return-form'), findsNothing);
    // Nothing was sent again: the receipt is the committed one.
    expect(backend.submits, hasLength(1));

    // Closing without leaving the receipt keeps it for the next opening.
    await _closeLookup(tester);
    await _pumpLookup(tester, backend);
    expect(_key('return-receipt'), findsOneWidget);

    // Leaving the receipt acknowledges it; the sale is refetched.
    await _tap(tester, _key('return-receipt-back'));
    expect(backend.finds.last, <String, Object?>{'saleId': draft.saleId});
    expect(_key('correction-detail'), findsOneWidget);
    await _closeLookup(tester);
    await _pumpLookup(tester, backend);
    expect(_key('return-receipt'), findsNothing);
    expect(_key('correction-folio'), findsOneWidget);
  });

  testWidgets('an acknowledged receipt lets a new return use a new key', (
    WidgetTester tester,
  ) async {
    final FakeCorrections backend = FakeCorrections();
    final Completer<SaleReturnReceipt> pending = Completer<SaleReturnReceipt>();
    await _pumpLookup(tester, backend);
    await _confirmPendingReturn(tester, backend, pending);
    final SaleReturnDraft first = backend.submits.single;
    await _closeLookup(tester);
    pending.complete(_receiptFor(first));
    await tester.pump();

    await _pumpLookup(tester, backend);
    await _tap(tester, _key('return-receipt-new-search'));
    expect(_key('correction-folio'), findsOneWidget);
    expect(backend.acknowledged, hasLength(1));
    expect(backend.completed, isNull);

    final Completer<SaleReturnReceipt> second = Completer<SaleReturnReceipt>();
    await _confirmPendingReturn(tester, backend, second);
    expect(backend.submits, hasLength(2));
    expect(backend.submits.last.idempotencyKey, isNot(first.idempotencyKey));
    second.complete(_receiptFor(backend.submits.last));
    await tester.pumpAndSettle();
    expect(_key('return-receipt'), findsOneWidget);
  });

  testWidgets('an uncertain submit after its form closed reopens locked', (
    WidgetTester tester,
  ) async {
    final FakeCorrections backend = FakeCorrections();
    final Completer<SaleReturnReceipt> pending = Completer<SaleReturnReceipt>();
    await _pumpLookup(tester, backend);
    await _confirmPendingReturn(tester, backend, pending);
    final SaleReturnDraft draft = backend.submits.single;

    await _closeLookup(tester);
    pending.completeError(const SaleUncertainException());
    await tester.pump();

    await _pumpLookup(tester, backend);
    expect(_key('return-form'), findsOneWidget);
    expect(find.text(returnUncertainMessage), findsOneWidget);
    expect(_key('return-confirm'), findsNothing);

    backend.submitResults.add(answerReplayed);
    await _tap(tester, _key('return-retry'));
    expect(backend.submits, <SaleReturnDraft>[draft, draft]);
    expect(_key('return-receipt'), findsOneWidget);
  });

  testWidgets('a rejected submit after its form closed leaves nothing', (
    WidgetTester tester,
  ) async {
    final FakeCorrections backend = FakeCorrections();
    final Completer<SaleReturnReceipt> pending = Completer<SaleReturnReceipt>();
    await _pumpLookup(tester, backend);
    await _confirmPendingReturn(tester, backend, pending);

    await _closeLookup(tester);
    pending.completeError(
      const SaleRejectedException(
        code: 'out-of-range',
        message: 'return exceeds the remaining sold quantity',
        reason: 'over-return',
      ),
    );
    await tester.pump();

    await _pumpLookup(tester, backend);
    expect(_key('correction-folio'), findsOneWidget);
    expect(_key('return-receipt'), findsNothing);
    expect(_key('return-form'), findsNothing);
    expect(backend.unresolved, isNull);
  });

  testWidgets('a stored unresolved return reopens its form; retry finishes', (
    WidgetTester tester,
  ) async {
    final SaleReturnDraft stored = returnDraft();
    final FakeCorrections backend = FakeCorrections(unresolved: stored)
      ..submitResults.add(answerReplayed);
    await _pumpLookup(tester, backend);

    expect(_key('return-form'), findsOneWidget);
    expect(find.text(returnUncertainMessage), findsOneWidget);
    expect(_key('return-confirm'), findsNothing);
    await _tap(tester, _key('return-retry'));
    expect(backend.submits.single, same(stored));
    expect(_key('return-receipt'), findsOneWidget);

    await _tap(tester, _key('return-receipt-back'));
    expect(backend.finds.single, <String, Object?>{'saleId': stored.saleId});
    expect(_key('correction-detail'), findsOneWidget);
  });
}
