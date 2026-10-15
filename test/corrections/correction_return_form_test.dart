import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/corrections/correction_draft.dart';
import 'package:lda_inventory/corrections/correction_receipt.dart';
import 'package:lda_inventory/corrections/correction_return_form.dart';
import 'package:lda_inventory/corrections/correction_sale.dart';
import 'package:lda_inventory/firebase/emulator_correction_gateway.dart';
import 'package:lda_inventory/firebase/emulator_sale_gateway.dart';
import 'package:lda_inventory/sales/sale_cart.dart';

import 'correction_fixtures.dart';
import 'correction_ui_fixtures.dart';

const Map<String, String> _names = <String, String>{
  'DEMO-RIBBON': 'Ribbon',
  'DEMO-PIN': 'Pin',
};

Finder _key(String value) => find.byKey(ValueKey<String>(value));

class _Harness {
  _Harness(this.backend);
  final FakeCorrections backend;
  final List<SaleReturnReceipt> completed = <SaleReturnReceipt>[];
  int backs = 0;
}

Future<_Harness> _pump(
  WidgetTester tester, {
  FakeCorrections? backend,
  CorrectableSale? sale,
}) async {
  final _Harness harness = _Harness(backend ?? FakeCorrections());
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: CorrectionReturnForm(
          sale: sale ?? lookupSale(),
          corrections: harness.backend.corrections,
          productNames: _names,
          onBack: () => harness.backs += 1,
          onCompleted: harness.completed.add,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return harness;
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

/// Waits past the preview debounce and lets the preview land.
Future<void> _settlePreview(WidgetTester tester) async {
  await tester.pump(returnPreviewDelay);
  await tester.pumpAndSettle();
}

Future<void> _enter(WidgetTester tester, String key, String text) async {
  await tester.ensureVisible(_key(key));
  await tester.enterText(_key(key), text);
  await tester.pump();
}

/// Selects the pin line (index 1) with [quantity] and the given reason.
Future<void> _fillPin(
  WidgetTester tester, {
  String quantity = '1',
  String reason = 'change-of-mind',
}) async {
  await _tap(tester, _key('return-line-select-1'));
  await _enter(tester, 'return-line-quantity-1', quantity);
  await _tap(tester, _key('return-reason-$reason'));
  await _settlePreview(tester);
}

bool _confirmEnabled(WidgetTester tester) =>
    tester.widget<FilledButton>(_key('return-confirm')).onPressed != null;

String? _fieldError(WidgetTester tester, String key) =>
    tester.widget<TextField>(_key(key)).decoration?.errorText;

void main() {
  testWidgets('lines are limited to the remaining quantity at precision', (
    WidgetTester tester,
  ) async {
    final FakeCorrections backend = FakeCorrections();
    await _pump(
      tester,
      backend: backend,
      sale: parseCorrectableSale(lookupSaleJson(ribbonReturned: 250)),
    );

    // The fully returned ribbon cannot be selected.
    expect(
      find.descendant(
        of: _key('return-line-0'),
        matching: find.text('Devuelto por completo'),
      ),
      findsOneWidget,
    );
    expect(_key('return-line-select-0'), findsNothing);
    expect(_key('return-line-quantity-0'), findsNothing);
    expect(find.text('Máximo: 3 piece'), findsNothing);

    await _tap(tester, _key('return-line-select-1'));
    await _tap(tester, _key('return-reason-other'));
    expect(find.text('Máximo: 3 piece'), findsOneWidget);
    for (final (String text, String error) in <(String, String)>[
      ('', 'Escribe una cantidad.'),
      ('1.5', 'Este producto solo admite cantidades enteras.'),
      ('0', 'La cantidad debe ser mayor que cero.'),
      ('4', 'No puedes devolver más de lo restante (3 piece).'),
      ('dos', 'Escribe una cantidad válida, por ejemplo 2 o 1.5.'),
    ]) {
      await _enter(tester, 'return-line-quantity-1', text);
      await _settlePreview(tester);
      expect(
        _fieldError(tester, 'return-line-quantity-1'),
        error,
        reason: text,
      );
      expect(_confirmEnabled(tester), isFalse, reason: text);
    }
    expect(backend.previews, isEmpty);

    await _enter(tester, 'return-line-quantity-1', '3');
    await _settlePreview(tester);
    expect(_fieldError(tester, 'return-line-quantity-1'), isNull);
    expect(backend.previews.single.toRequest()['lines'], <Object?>[
      <String, Object?>{'lineIndex': 1, 'quantity': '3', 'condition': 'good'},
    ]);
  });

  testWidgets('decimal lines accept up to their precision, BigInt-exact', (
    WidgetTester tester,
  ) async {
    final FakeCorrections backend = FakeCorrections();
    await _pump(tester, backend: backend);
    await _tap(tester, _key('return-line-select-0'));
    await _tap(tester, _key('return-reason-wrong-product'));
    expect(find.text('Máximo: 2.00 meter'), findsOneWidget);

    await _enter(tester, 'return-line-quantity-0', '1.255');
    await _settlePreview(tester);
    expect(
      _fieldError(tester, 'return-line-quantity-0'),
      'Usa como máximo 2 decimales.',
    );
    await _enter(tester, 'return-line-quantity-0', '2.01');
    await _settlePreview(tester);
    expect(
      _fieldError(tester, 'return-line-quantity-0'),
      'No puedes devolver más de lo restante (2.00 meter).',
    );
    await _enter(tester, 'return-line-quantity-0', '100000');
    await _settlePreview(tester);
    expect(
      _fieldError(tester, 'return-line-quantity-0'),
      'No puedes devolver más de lo restante (2.00 meter).',
    );
    expect(backend.previews, isEmpty);

    await _enter(tester, 'return-line-quantity-0', '2.00');
    await _tap(tester, _key('return-line-condition-0-factory-defect'));
    await _settlePreview(tester);
    expect(backend.previews.single.toRequest(), <String, Object?>{
      'saleId': lookupSale().saleId,
      'reason': 'wrong-product',
      'lines': <Object?>[
        <String, Object?>{
          'lineIndex': 0,
          'quantity': '2.00',
          'condition': 'factory-defect',
        },
      ],
    });
  });

  testWidgets('the preview shows the refund, IVA, total and method', (
    WidgetTester tester,
  ) async {
    await _pump(tester);
    expect(
      find.text(
        'Elige productos, cantidades y motivo para calcular el reembolso.',
      ),
      findsOneWidget,
    );
    await _tap(tester, _key('return-line-select-0'));
    await _enter(tester, 'return-line-quantity-0', '1');
    await _fillPin(tester);

    final Finder preview = _key('return-preview');
    for (final String text in <String>[
      'Ribbon · 1.00 meter · En buen estado',
      '11.60 MXN',
      'Pin · 1 piece · En buen estado',
      '2.50 MXN',
      'IVA reembolsado: 1.60 MXN',
      'Total a reembolsar: 14.10 MXN',
      'Se reembolsa por: Tarjeta',
    ]) {
      expect(
        find.descendant(of: preview, matching: find.text(text)),
        findsOneWidget,
        reason: text,
      );
    }
  });

  testWidgets('an uninvoiced preview shows no IVA', (
    WidgetTester tester,
  ) async {
    await _pump(tester, sale: uninvoicedSale());
    await _tap(tester, _key('return-line-select-0'));
    await _enter(tester, 'return-line-quantity-0', '2');
    await _tap(tester, _key('return-reason-change-of-mind'));
    await _settlePreview(tester);
    expect(find.text('Total a reembolsar: 5.00 MXN'), findsOneWidget);
    expect(find.text('Se reembolsa por: Efectivo'), findsOneWidget);
    expect(find.textContaining('IVA'), findsNothing);
  });

  testWidgets('every change re-previews and a late older preview is ignored', (
    WidgetTester tester,
  ) async {
    final FakeCorrections backend = FakeCorrections();
    final Completer<SaleReturnPreview> first = Completer<SaleReturnPreview>();
    final Completer<SaleReturnPreview> second = Completer<SaleReturnPreview>();
    backend.previewResults
      ..add(first)
      ..add(second);
    await _pump(tester, backend: backend);
    await _fillPin(tester);
    expect(backend.previews, hasLength(1));
    expect(find.text('Calculando reembolso…'), findsOneWidget);
    expect(_confirmEnabled(tester), isFalse);

    // Debounced: typing several characters sends one preview.
    await _enter(tester, 'return-line-quantity-1', '');
    await _enter(tester, 'return-line-quantity-1', '2');
    await _settlePreview(tester);
    expect(backend.previews, hasLength(2));
    expect(backend.previews.last.lines.single.quantity, '2');

    first.complete(
      SaleReturnPreview.fromCallable(
        returnPreviewJsonFor(backend.previews.first),
        request: backend.previews.first,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Total a reembolsar: 2.50 MXN'), findsNothing);
    expect(_confirmEnabled(tester), isFalse);

    second.complete(
      SaleReturnPreview.fromCallable(
        returnPreviewJsonFor(backend.previews.last),
        request: backend.previews.last,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Total a reembolsar: 5.00 MXN'), findsOneWidget);
    expect(_confirmEnabled(tester), isTrue);

    // A condition or reason change makes the shown preview stale at once.
    await tester.tap(_key('return-line-condition-1-factory-defect'));
    await tester.pump();
    expect(find.text('Total a reembolsar: 5.00 MXN'), findsNothing);
    expect(_confirmEnabled(tester), isFalse);
    await _settlePreview(tester);
    expect(
      backend.previews.last.lines.single.condition,
      ReturnCondition.factoryDefect,
    );
    expect(_confirmEnabled(tester), isTrue);
    await tester.tap(_key('return-reason-factory-defect'));
    await tester.pump();
    expect(_confirmEnabled(tester), isFalse);
    await _settlePreview(tester);
    expect(backend.previews.last.reason, CorrectionReason.factoryDefect);
    expect(_confirmEnabled(tester), isTrue);
  });

  testWidgets('a failed preview disables confirmation and offers a retry', (
    WidgetTester tester,
  ) async {
    final FakeCorrections backend = FakeCorrections()
      ..previewResults.add(const CorrectionProtocolException())
      ..previewResults.add(
        const SaleRejectedException(
          code: 'failed-precondition',
          message: 'sale is outside the correction window',
          reason: correctionWindowClosedReason,
        ),
      );
    await _pump(tester, backend: backend);
    await _fillPin(tester);
    expect(find.text('No se pudo calcular el reembolso.'), findsOneWidget);
    expect(_confirmEnabled(tester), isFalse);

    await _tap(tester, _key('return-preview-retry'));
    await _settlePreview(tester);
    expect(
      find.text(
        'La venta ya está fuera del plazo de 15 días para correcciones.',
      ),
      findsOneWidget,
    );
    expect(_confirmEnabled(tester), isFalse);

    await _tap(tester, _key('return-preview-retry'));
    await _settlePreview(tester);
    expect(backend.previews, hasLength(3));
    expect(_confirmEnabled(tester), isTrue);
  });

  testWidgets('confirmation needs a fresh preview and a valid note', (
    WidgetTester tester,
  ) async {
    final FakeCorrections backend = FakeCorrections();
    await _pump(tester, backend: backend);
    expect(_confirmEnabled(tester), isFalse);
    await _tap(tester, _key('return-line-select-1'));
    await _enter(tester, 'return-line-quantity-1', '1');
    await _settlePreview(tester);
    // No reason yet: nothing to preview or confirm.
    expect(backend.previews, isEmpty);
    expect(_confirmEnabled(tester), isFalse);
    await _tap(tester, _key('return-reason-other'));
    await _settlePreview(tester);
    expect(_confirmEnabled(tester), isTrue);

    await _enter(tester, 'return-note', 'x' * 501);
    expect(
      _fieldError(tester, 'return-note'),
      'La nota admite como máximo 500 caracteres.',
    );
    expect(_confirmEnabled(tester), isFalse);
    // The note is not previewed, so fixing it needs no new preview.
    await _enter(tester, 'return-note', '  Caja dañada  ');
    expect(_confirmEnabled(tester), isTrue);
    expect(backend.previews, hasLength(1));

    await _tap(tester, _key('return-confirm'));
    final SaleReturnDraft draft = backend.submits.single;
    expect(draft.note, 'Caja dañada');
    expect(draft.previewRequest, backend.previews.single);
  });

  testWidgets('a deselected line leaves the request and the preview', (
    WidgetTester tester,
  ) async {
    final FakeCorrections backend = FakeCorrections();
    await _pump(tester, backend: backend);
    await _tap(tester, _key('return-line-select-0'));
    await _enter(tester, 'return-line-quantity-0', '0.5');
    await _fillPin(tester);
    expect(backend.previews.last.lines, hasLength(2));
    await _tap(tester, _key('return-line-select-0'));
    await _settlePreview(tester);
    expect(
      backend.previews.last.lines.map((CorrectionLine line) => line.lineIndex),
      <int>[1],
    );
    await _tap(tester, _key('return-line-select-1'));
    await _settlePreview(tester);
    expect(backend.previews, hasLength(2));
    expect(_confirmEnabled(tester), isFalse);
  });

  testWidgets('a success hands over the receipt', (WidgetTester tester) async {
    final FakeCorrections backend = FakeCorrections();
    final _Harness harness = await _pump(tester, backend: backend);
    await _fillPin(tester);
    await _tap(tester, _key('return-confirm'));
    expect(
      harness.completed.single.returnId,
      backend.submits.single.idempotencyKey,
    );
    expect(harness.completed.single.totalCentavos, 250);
    expect(backend.unresolved, isNull);
  });

  testWidgets('an uncertain submit locks the form; retry sends the same key', (
    WidgetTester tester,
  ) async {
    final FakeCorrections backend = FakeCorrections()
      ..submitResults.add(const SaleUncertainException());
    final _Harness harness = await _pump(tester, backend: backend);
    await _fillPin(tester, quantity: '2');
    await _tap(tester, _key('return-confirm'));

    expect(
      find.text(
        'No sabemos si la devolución se registró. Reintenta la misma '
        'devolución antes de hacer otro cambio.',
      ),
      findsOneWidget,
    );
    expect(_key('return-confirm'), findsNothing);
    expect(_key('return-retry'), findsOneWidget);
    expect(
      tester.widget<TextField>(_key('return-line-quantity-1')).enabled,
      isFalse,
    );
    expect(
      tester.widget<Checkbox>(_key('return-line-select-1')).onChanged,
      isNull,
    );
    expect(
      tester.widget<ChoiceChip>(_key('return-reason-other')).onSelected,
      isNull,
    );
    expect(tester.widget<TextField>(_key('return-note')).enabled, isFalse);
    // No preview runs while locked.
    await _settlePreview(tester);
    expect(backend.previews, hasLength(1));

    await _tap(tester, _key('return-retry'));
    expect(backend.submits, hasLength(2));
    expect(backend.submits.last, same(backend.submits.first));
    expect(
      backend.submits.last.idempotencyKey,
      backend.submits.first.idempotencyKey,
    );
    expect(
      harness.completed.single.returnId,
      backend.submits.first.idempotencyKey,
    );
  });

  testWidgets('a stored unresolved return reopens locked to that draft', (
    WidgetTester tester,
  ) async {
    final FakeCorrections backend = FakeCorrections(unresolved: returnDraft());
    final _Harness harness = await _pump(tester, backend: backend);
    expect(_key('return-retry'), findsOneWidget);
    expect(
      tester.widget<TextField>(_key('return-line-quantity-0')).controller!.text,
      '1',
    );
    expect(
      tester.widget<ChoiceChip>(_key('return-reason-change-of-mind')).selected,
      isTrue,
    );
    expect(
      tester
          .widget<ChoiceChip>(_key('return-line-condition-1-factory-defect'))
          .selected,
      isTrue,
    );
    expect(backend.previews, isEmpty);
    await _tap(tester, _key('return-retry'));
    expect(backend.submits.single.idempotencyKey, returnKey);
    expect(harness.completed.single.returnId, returnKey);
  });

  testWidgets('another unresolved correction blocks a new return', (
    WidgetTester tester,
  ) async {
    final FakeCorrections backend = FakeCorrections(unresolved: returnDraft());
    await _pump(tester, backend: backend, sale: uninvoicedSale());
    expect(
      find.text(
        'Hay otra corrección sin confirmar. Reinténtala antes de registrar '
        'una nueva.',
      ),
      findsOneWidget,
    );
    await _tap(tester, _key('return-line-select-0'));
    await _enter(tester, 'return-line-quantity-0', '1');
    await _tap(tester, _key('return-reason-other'));
    await _settlePreview(tester);
    expect(_confirmEnabled(tester), isFalse);
  });

  testWidgets('an unseen committed return also blocks a new return', (
    WidgetTester tester,
  ) async {
    final SaleReturnDraft committed = returnDraft();
    final FakeCorrections backend = FakeCorrections()
      ..completed = CompletedCorrection.of(
        committed,
        SaleReturnReceipt.fromCallable(returnResponse(), draft: committed),
      );
    await _pump(tester, backend: backend, sale: uninvoicedSale());
    // Not the retry message: the committed one only needs its receipt seen.
    expect(
      find.text(
        'Hay una corrección registrada pendiente de revisar. Abre su '
        'comprobante para continuar.',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('Reinténtala'), findsNothing);
    await _tap(tester, _key('return-line-select-0'));
    await _enter(tester, 'return-line-quantity-0', '1');
    await _tap(tester, _key('return-reason-other'));
    await _settlePreview(tester);
    expect(_confirmEnabled(tester), isFalse);
  });

  testWidgets('a rejection re-previews and explains it in Spanish', (
    WidgetTester tester,
  ) async {
    final FakeCorrections backend = FakeCorrections()
      ..submitResults.add(
        const SaleRejectedException(
          code: 'out-of-range',
          message: 'return exceeds the remaining sold quantity',
          reason: correctionOverReturnReason,
        ),
      )
      ..submitResults.add(
        const SaleRejectedException(
          code: 'failed-precondition',
          message: 'sale is outside the correction window',
          reason: correctionWindowClosedReason,
        ),
      )
      ..submitResults.add(
        const SaleRejectedException(code: 'not-found', message: 'missing'),
      );
    await _pump(tester, backend: backend);
    await _fillPin(tester);

    for (final String message in <String>[
      'La cantidad supera lo que queda por devolver. Revisa las cantidades.',
      'La venta ya está fuera del plazo de 15 días para correcciones.',
      'La devolución fue rechazada. Revisa los datos e intenta de nuevo.',
    ]) {
      final int previews = backend.previews.length;
      await _tap(tester, _key('return-confirm'));
      expect(find.text(message), findsOneWidget, reason: message);
      expect(_key('return-retry'), findsNothing);
      // The rejection re-runs the preview right away.
      await tester.pumpAndSettle();
      expect(backend.previews.length, previews + 1, reason: message);
      expect(_confirmEnabled(tester), isTrue, reason: message);
    }
    expect(backend.submits, hasLength(3));
    // Each new confirmation is a new draft with a new key.
    expect(
      backend.submits
          .map((SaleReturnDraft draft) => draft.idempotencyKey)
          .toSet(),
      hasLength(3),
    );
  });

  testWidgets('a session failure without a stored draft just explains', (
    WidgetTester tester,
  ) async {
    final FakeCorrections backend = FakeCorrections()
      ..submitResults.add(const SaleSessionException());
    await _pump(tester, backend: backend);
    await _fillPin(tester);
    await _tap(tester, _key('return-confirm'));
    expect(
      find.text('Tu sesión cambió. Inicia sesión de nuevo para continuar.'),
      findsOneWidget,
    );
    expect(_key('return-retry'), findsNothing);
    expect(backend.submits, isEmpty);
  });

  testWidgets('back returns to the sale', (WidgetTester tester) async {
    final _Harness harness = await _pump(tester);
    await _tap(tester, _key('return-back'));
    expect(harness.backs, 1);
  });

  for (final (Size size, double scale) in responsiveViewports) {
    testWidgets(
      'a previewed return fits ${size.width.toInt()}px at text scale $scale',
      (WidgetTester tester) async {
        useViewport(tester, size, scale);
        await _pump(tester);
        await _fillPin(tester);
        await _settlePreview(tester);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
