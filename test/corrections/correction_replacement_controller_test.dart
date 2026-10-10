import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/corrections/correction_draft.dart';
import 'package:lda_inventory/corrections/correction_form_support.dart';
import 'package:lda_inventory/corrections/correction_replacement_controller.dart';
import 'package:lda_inventory/firebase/emulator_sale_gateway.dart';
import 'package:lda_inventory/sales/sale_cart.dart';

import 'correction_fixtures.dart';
import 'correction_ui_fixtures.dart';

/// A replacement form with the pin line (index 1) selected at [quantity].
CorrectionReplacementController _filled(
  FakeCorrections backend, {
  String quantity = '1',
}) {
  final CorrectionReplacementController form = CorrectionReplacementController(
    sale: lookupSale(),
    corrections: backend.corrections,
  );
  form.setSelected(1, true);
  form.lines[1].quantity.text = quantity;
  form.quantityChanged();
  return form;
}

void main() {
  testWidgets('another unresolved correction blocks the form, unlocked', (
    WidgetTester tester,
  ) async {
    final FakeCorrections backend = FakeCorrections();
    final CorrectionReplacementController form = _filled(backend);
    addTearDown(form.dispose);
    expect(form.canConfirm, isTrue);
    // Another correction was stored after the form opened.
    backend.unresolved = returnDraft();

    await form.confirm();
    expect(backend.replacementSubmits, isEmpty);
    expect(form.isSubmitting, isFalse);
    expect(form.isLocked, isFalse);
    expect(form.message, correctionUnresolvedMessage);
    expect(form.canConfirm, isFalse);
  });

  testWidgets('a stale submission with nothing stored explains and unlocks', (
    WidgetTester tester,
  ) async {
    final FakeCorrections backend = FakeCorrections();
    final Completer<Object?> gate = Completer<Object?>();
    backend.replacementResults.add(gate);
    final CorrectionReplacementController form = _filled(backend);
    addTearDown(form.dispose);

    final Future<void> sending = form.confirm();
    expect(form.isSubmitting, isTrue);
    // A newer attempt resolved the stored draft first.
    backend.unresolved = null;
    gate.completeError(const SaleStaleException());
    await sending;

    expect(form.isSubmitting, isFalse);
    expect(form.isLocked, isFalse);
    expect(form.message, correctionStaleMessage);
    expect(form.canEdit, isTrue);
  });

  testWidgets('a session change with a stored draft re-locks to that draft', (
    WidgetTester tester,
  ) async {
    final FakeCorrections backend = FakeCorrections();
    final Completer<Object?> gate = Completer<Object?>();
    backend.replacementResults.add(gate);
    final CorrectionReplacementController form = _filled(backend);
    addTearDown(form.dispose);

    final Future<void> sending = form.confirm();
    // The store now holds another draft of this sale: two pins, not one.
    final SaleReplacementDraft stored = replacementDraft();
    backend.unresolved = stored;
    gate.completeError(const SaleSessionException());
    await sending;

    expect(form.isSubmitting, isFalse);
    expect(form.isLocked, isTrue);
    expect(form.canEdit, isFalse);
    expect(form.message, replacementUncertainMessage);
    expect(form.lines[1].selected, isTrue);
    expect(form.lines[1].quantity.text, '2');

    // The retry sends exactly the stored draft.
    await form.retrySubmit();
    expect(backend.replacementSubmits.last, same(stored));
    expect(form.isLocked, isFalse);
  });
}
