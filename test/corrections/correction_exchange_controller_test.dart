import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/corrections/correction_draft.dart';
import 'package:lda_inventory/corrections/correction_exchange_controller.dart';
import 'package:lda_inventory/corrections/correction_sale.dart';
import 'package:lda_inventory/sales/sale_cart.dart';

import 'correction_fixtures.dart';
import 'correction_ui_fixtures.dart';

const Duration _delay = Duration(milliseconds: 10);

String _noKey() => throw StateError('no key');

void main() {
  testWidgets('a confirm whose draft drifted from the preview re-previews', (
    WidgetTester tester,
  ) async {
    final FakeCorrections backend = FakeCorrections();
    int built = 0;
    final CorrectionExchangeController form = CorrectionExchangeController(
      sale: lookupSale(),
      corrections: backend.corrections,
      products: exchangeCatalog,
      previewDelay: _delay,
      // The derivation drifts once: the draft would take three tapes while
      // the seller was shown the settlement for two.
      buildDraft:
          ({
            required CorrectableSale sale,
            required String branchId,
            required CorrectionReason reason,
            required List<ReturnLineInput> returnLines,
            required SaleCart newItems,
            SaleExchangePayment? differencePayment,
            String? note,
            String Function() createKey = _noKey,
          }) {
            built += 1;
            return SaleExchangeDraft.create(
              sale: sale,
              branchId: branchId,
              reason: reason,
              returnLines: returnLines,
              newItems: built == 1
                  ? newItems.updateQuantity('DEMO-TAPE', '3')
                  : newItems,
              differencePayment: differencePayment,
              note: note,
              createKey: createKey,
            );
          },
    );
    addTearDown(form.dispose);
    form
      ..setSelected(1, true)
      ..setReason(CorrectionReason.wrongProduct)
      ..addProduct('DEMO-TAPE');
    form.returnLines[1].quantity.text = '1';
    form.newLines.single.quantity.text = '2';
    form.quantityChanged();
    await tester.pump(_delay);
    expect(form.canConfirm, isTrue);
    final SaleExchangePreviewRequest shown = backend.exchangePreviews.single;

    await form.confirm();
    // Nothing was sent; the same form was previewed again right away.
    expect(backend.exchangeSubmits, isEmpty);
    expect(backend.exchangePreviews, hasLength(2));
    expect(backend.exchangePreviews.last, shown);
    await tester.pump();
    expect(form.previewStatus, ExchangePreviewStatus.ready);
    expect(form.preview?.request, shown);
    expect(form.canConfirm, isTrue);

    await form.confirm();
    final SaleExchangeDraft sent = backend.exchangeSubmits.single;
    expect(sent.previewRequest, shown);
    expect(sent.differencePayment?.amountCentavos, 2070);
  });

  testWidgets('a quantity edit revalidates and re-previews', (
    WidgetTester tester,
  ) async {
    final FakeCorrections backend = FakeCorrections();
    final CorrectionExchangeController form = CorrectionExchangeController(
      sale: lookupSale(),
      corrections: backend.corrections,
      products: exchangeCatalog,
      previewDelay: _delay,
    );
    addTearDown(form.dispose);
    form
      ..setSelected(1, true)
      ..setReason(CorrectionReason.other)
      ..addProduct('DEMO-TAPE');
    form.returnLines[1].quantity.text = '1';
    final ExchangeNewLineEntry tape = form.newLines.single;
    tape.quantity.text = '2';
    form.quantityChanged();
    await tester.pump(_delay);
    expect(backend.exchangePreviews, hasLength(1));

    tape.quantity.text = '2.5';
    form.quantityChanged();
    expect(tape.error, 'Este producto solo admite cantidades enteras.');
    expect(form.preview, isNull);
    expect(form.canConfirm, isFalse);
    await tester.pump(_delay);
    expect(backend.exchangePreviews, hasLength(1));

    tape.quantity.text = '4';
    form.quantityChanged();
    expect(tape.error, isNull);
    await tester.pump(_delay);
    expect(backend.exchangePreviews.last.newItems.lines.single.quantity, '4');
    expect(form.canConfirm, isTrue);
  });
}
