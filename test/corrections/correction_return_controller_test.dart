import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/corrections/correction_draft.dart';
import 'package:lda_inventory/corrections/correction_return_controller.dart';
import 'package:lda_inventory/corrections/correction_sale.dart';

import 'correction_fixtures.dart';
import 'correction_ui_fixtures.dart';

const Duration _delay = Duration(milliseconds: 10);

CorrectionReturnController _controller(
  FakeCorrections backend, {
  ReturnDraftBuilder buildDraft = SaleReturnDraft.create,
}) => CorrectionReturnController(
  sale: lookupSale(),
  corrections: backend.corrections,
  previewDelay: _delay,
  buildDraft: buildDraft,
);

void main() {
  testWidgets('a quantity edit revalidates and re-previews', (
    WidgetTester tester,
  ) async {
    final FakeCorrections backend = FakeCorrections();
    final CorrectionReturnController form = _controller(backend);
    addTearDown(form.dispose);
    form
      ..setSelected(1, true)
      ..setReason(CorrectionReason.changeOfMind);
    final ReturnLineEntry pin = form.lines[1];

    pin.quantity.text = '1';
    form.quantityChanged();
    expect(pin.error, isNull);
    expect(form.previewStatus, ReturnPreviewStatus.loading);
    expect(backend.previews, isEmpty);
    await tester.pump(_delay);
    expect(backend.previews.single.lines.single.quantity, '1');
    expect(form.canConfirm, isTrue);

    // An invalid edit shows its error and never previews.
    pin.quantity.text = '4';
    form.quantityChanged();
    expect(pin.error, 'No puedes devolver más de lo restante (3 piece).');
    expect(form.previewStatus, ReturnPreviewStatus.incomplete);
    expect(form.preview, isNull);
    expect(form.canConfirm, isFalse);
    await tester.pump(_delay);
    expect(backend.previews, hasLength(1));

    pin.quantity.text = '2';
    form.quantityChanged();
    expect(pin.error, isNull);
    // The previous preview answers another quantity: not shown.
    expect(form.preview, isNull);
    await tester.pump(_delay);
    expect(backend.previews, hasLength(2));
    expect(backend.previews.last.lines.single.quantity, '2');
    expect(form.preview?.request, backend.previews.last);
    expect(form.canConfirm, isTrue);
  });

  testWidgets('a quantity edit is ignored while the form is locked', (
    WidgetTester tester,
  ) async {
    final FakeCorrections backend = FakeCorrections(unresolved: returnDraft());
    final CorrectionReturnController form = _controller(backend);
    addTearDown(form.dispose);
    expect(form.isLocked, isTrue);
    form.lines[0].quantity.text = '9';
    form.quantityChanged();
    await tester.pump(_delay);
    expect(form.lines[0].error, isNull);
    expect(backend.previews, isEmpty);
  });

  testWidgets('a confirm whose draft drifted from the preview re-previews', (
    WidgetTester tester,
  ) async {
    final FakeCorrections backend = FakeCorrections();
    int built = 0;
    final CorrectionReturnController form = _controller(
      backend,
      // The derivation drifts once: the draft would return two pins while
      // the seller was shown the refund for one.
      buildDraft:
          ({
            required CorrectableSale sale,
            required String branchId,
            required CorrectionReason reason,
            required List<ReturnLineInput> lines,
            String? note,
            String Function() createKey = _noKey,
          }) {
            built += 1;
            return SaleReturnDraft.create(
              sale: sale,
              branchId: branchId,
              reason: reason,
              note: note,
              createKey: createKey,
              lines: built == 1
                  ? const <ReturnLineInput>[
                      ReturnLineInput(
                        lineIndex: 1,
                        quantity: '2',
                        condition: ReturnCondition.good,
                      ),
                    ]
                  : lines,
            );
          },
    );
    addTearDown(form.dispose);
    form
      ..setSelected(1, true)
      ..setReason(CorrectionReason.changeOfMind);
    form.lines[1].quantity.text = '1';
    form.quantityChanged();
    await tester.pump(_delay);
    expect(form.canConfirm, isTrue);
    final SaleReturnPreviewRequest shown = backend.previews.single;

    await form.confirm();
    // Nothing was sent; the same form was previewed again right away.
    expect(backend.submits, isEmpty);
    expect(backend.previews, hasLength(2));
    expect(backend.previews.last, shown);
    await tester.pump();
    expect(form.previewStatus, ReturnPreviewStatus.ready);
    expect(form.preview?.request, shown);
    expect(form.message, isNull);
    expect(form.canConfirm, isTrue);

    await form.confirm();
    expect(backend.submits.single.lines.single.quantity, '1');
  });
}

String _noKey() => throw StateError('no key');
