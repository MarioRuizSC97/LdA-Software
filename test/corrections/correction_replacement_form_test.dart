import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/corrections/correction_draft.dart';
import 'package:lda_inventory/corrections/correction_receipt.dart';
import 'package:lda_inventory/corrections/correction_replacement_form.dart';
import 'package:lda_inventory/corrections/correction_sale.dart';
import 'package:lda_inventory/firebase/emulator_correction_gateway.dart';
import 'package:lda_inventory/firebase/emulator_sale_gateway.dart';
import 'package:lda_inventory/sales/sale_cart.dart';

import '../sales/sale_fixtures.dart';
import 'correction_fixtures.dart';
import 'correction_ui_fixtures.dart';

Finder _key(String value) => find.byKey(ValueKey<String>(value));

class _Harness {
  _Harness(this.backend);
  final FakeCorrections backend;
  final List<SaleReplacementReceipt> completed = <SaleReplacementReceipt>[];
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
        body: CorrectionReplacementForm(
          sale: sale ?? lookupSale(),
          corrections: harness.backend.corrections,
          productNames: catalogNames,
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

Future<void> _enter(WidgetTester tester, String key, String text) async {
  await tester.ensureVisible(_key(key));
  await tester.enterText(_key(key), text);
  await tester.pump();
}

/// Selects the pin line (index 1) with [quantity].
Future<void> _fillPin(WidgetTester tester, {String quantity = '2'}) async {
  await _tap(tester, _key('replacement-line-select-1'));
  await _enter(tester, 'replacement-line-quantity-1', quantity);
}

bool _confirmEnabled(WidgetTester tester) =>
    tester.widget<FilledButton>(_key('replacement-confirm')).onPressed != null;

String? _fieldError(WidgetTester tester, String key) =>
    tester.widget<TextField>(_key(key)).decoration?.errorText;

void main() {
  testWidgets('shows the fixed reason, no charge and no amount preview', (
    WidgetTester tester,
  ) async {
    final FakeCorrections backend = FakeCorrections();
    await _pump(tester, backend: backend);
    expect(find.text('Reemplazo por defecto de fábrica'), findsOneWidget);
    expect(find.text('Venta NTE-3F2A-9C1B'), findsOneWidget);
    expect(find.text('Motivo: Defecto de fábrica'), findsOneWidget);
    expect(find.text('Sin costo para el cliente'), findsOneWidget);
    // The reason is fixed: there is nothing to choose.
    expect(find.byType(ChoiceChip), findsNothing);
    await _fillPin(tester);
    await tester.pumpAndSettle();
    expect(backend.previews, isEmpty);
    expect(backend.exchangePreviews, isEmpty);
    expect(_confirmEnabled(tester), isTrue);
  });

  testWidgets('lines are limited to the remaining quantity at precision', (
    WidgetTester tester,
  ) async {
    await _pump(
      tester,
      sale: parseCorrectableSale(lookupSaleJson(ribbonReturned: 250)),
    );
    // A fully returned line has nothing left to replace (decision 11).
    expect(
      find.descendant(
        of: _key('replacement-line-0'),
        matching: find.text('Sin cantidad restante'),
      ),
      findsOneWidget,
    );
    expect(_key('replacement-line-select-0'), findsNothing);
    expect(_confirmEnabled(tester), isFalse);

    await _tap(tester, _key('replacement-line-select-1'));
    expect(find.text('Máximo: 3 piece'), findsOneWidget);
    for (final (String text, String error) in <(String, String)>[
      ('', 'Escribe una cantidad.'),
      ('1.5', 'Este producto solo admite cantidades enteras.'),
      ('0', 'La cantidad debe ser mayor que cero.'),
      ('4', 'No puedes reemplazar más de lo restante (3 piece).'),
      ('abc', 'Escribe una cantidad válida, por ejemplo 2 o 1.5.'),
    ]) {
      await _enter(tester, 'replacement-line-quantity-1', text);
      expect(
        _fieldError(tester, 'replacement-line-quantity-1'),
        error,
        reason: text,
      );
      expect(_confirmEnabled(tester), isFalse, reason: text);
    }
    await _enter(tester, 'replacement-line-quantity-1', '3');
    expect(_fieldError(tester, 'replacement-line-quantity-1'), isNull);
    expect(_confirmEnabled(tester), isTrue);
  });

  testWidgets('decimal lines use the product precision', (
    WidgetTester tester,
  ) async {
    await _pump(tester);
    await _tap(tester, _key('replacement-line-select-0'));
    await _enter(tester, 'replacement-line-quantity-0', '1.255');
    expect(
      _fieldError(tester, 'replacement-line-quantity-0'),
      'Usa como máximo 2 decimales.',
    );
    await _enter(tester, 'replacement-line-quantity-0', '2.01');
    expect(
      _fieldError(tester, 'replacement-line-quantity-0'),
      'No puedes reemplazar más de lo restante (2.00 meter).',
    );
    await _enter(tester, 'replacement-line-quantity-0', '2.00');
    expect(_fieldError(tester, 'replacement-line-quantity-0'), isNull);
    expect(_confirmEnabled(tester), isTrue);
  });

  testWidgets('confirm sends the exact replacement and completes', (
    WidgetTester tester,
  ) async {
    final FakeCorrections backend = FakeCorrections();
    final _Harness harness = await _pump(tester, backend: backend);
    await _fillPin(tester);
    await _enter(tester, 'replacement-note', '  Broken clasp  ');
    await _tap(tester, _key('replacement-confirm'));

    final SaleReplacementDraft draft = backend.replacementSubmits.single;
    expect(draft.toRequest(), <String, Object?>{
      'idempotencyKey': '00000000-0000-4000-8000-000000000001',
      'saleId': saleKey,
      'lines': <Object?>[
        <String, Object?>{'lineIndex': 1, 'quantity': '2'},
      ],
      'note': 'Broken clasp',
    });
    expect(harness.completed.single.replacementId, draft.idempotencyKey);
    expect(harness.completed.single.replayed, isFalse);
  });

  testWidgets('an over-long note blocks confirmation', (
    WidgetTester tester,
  ) async {
    await _pump(tester);
    await _fillPin(tester);
    await _enter(tester, 'replacement-note', 'x' * 501);
    expect(
      _fieldError(tester, 'replacement-note'),
      'La nota admite como máximo 500 caracteres.',
    );
    expect(_confirmEnabled(tester), isFalse);
  });

  testWidgets('an uncertain submit locks the form to a same-key retry', (
    WidgetTester tester,
  ) async {
    final FakeCorrections backend = FakeCorrections()
      ..replacementResults.add(const SaleUncertainException())
      ..replacementResults.add(answerReplayed);
    final _Harness harness = await _pump(tester, backend: backend);
    await _fillPin(tester);
    await _tap(tester, _key('replacement-confirm'));

    expect(
      find.text(
        'No sabemos si el reemplazo se registró. Reintenta el mismo '
        'reemplazo antes de hacer otro cambio.',
      ),
      findsOneWidget,
    );
    expect(_key('replacement-confirm'), findsNothing);
    expect(
      tester.widget<TextField>(_key('replacement-line-quantity-1')).enabled,
      isFalse,
    );
    expect(
      tester.widget<Checkbox>(_key('replacement-line-select-1')).onChanged,
      isNull,
    );

    await _tap(tester, _key('replacement-retry'));
    expect(backend.replacementSubmits, hasLength(2));
    expect(
      backend.replacementSubmits.last,
      same(backend.replacementSubmits.first),
    );
    expect(harness.completed.single.replayed, isTrue);
  });

  testWidgets('rejections unlock the form and explain them in Spanish', (
    WidgetTester tester,
  ) async {
    final FakeCorrections backend = FakeCorrections()
      ..replacementResults.addAll(<Object>[
        const SaleRejectedException(
          code: 'failed-precondition',
          message: 'insufficient stock',
          reason: 'insufficient-stock',
        ),
        const SaleRejectedException(
          code: 'out-of-range',
          message: 'replacement exceeds the remaining returnable quantity',
          reason: correctionOverReturnReason,
        ),
        const SaleRejectedException(
          code: 'failed-precondition',
          message: 'sale is outside the correction window',
          reason: correctionWindowClosedReason,
        ),
        const SaleRejectedException(code: 'not-found', message: 'missing'),
      ]);
    await _pump(tester, backend: backend);
    await _fillPin(tester);
    for (final String message in <String>[
      'Sin existencias suficientes para reemplazar',
      'La cantidad supera lo que queda por reemplazar. Revisa las cantidades.',
      'La venta ya está fuera del plazo de 15 días para correcciones.',
      'El reemplazo fue rechazado. Revisa los datos e intenta de nuevo.',
    ]) {
      await _tap(tester, _key('replacement-confirm'));
      expect(find.text(message), findsOneWidget, reason: message);
      expect(_key('replacement-retry'), findsNothing);
      expect(_confirmEnabled(tester), isTrue, reason: message);
    }
    expect(
      backend.replacementSubmits
          .map((SaleReplacementDraft draft) => draft.idempotencyKey)
          .toSet(),
      hasLength(4),
    );
    expect(backend.unresolved, isNull);
  });

  testWidgets('a stored unresolved replacement reopens locked to it', (
    WidgetTester tester,
  ) async {
    final FakeCorrections backend = FakeCorrections(
      unresolved: replacementDraft(),
    );
    final _Harness harness = await _pump(tester, backend: backend);
    expect(_key('replacement-retry'), findsOneWidget);
    expect(
      tester
          .widget<TextField>(_key('replacement-line-quantity-1'))
          .controller!
          .text,
      '2',
    );
    await _tap(tester, _key('replacement-retry'));
    expect(backend.replacementSubmits.single.idempotencyKey, replacementKey);
    expect(harness.completed.single.replacementId, replacementKey);
  });

  testWidgets('another unresolved or unseen correction blocks it', (
    WidgetTester tester,
  ) async {
    final FakeCorrections unresolved = FakeCorrections(
      unresolved: returnDraft(),
    );
    await _pump(tester, backend: unresolved);
    expect(
      find.text(
        'Hay otra corrección sin confirmar. Reinténtala antes de registrar '
        'una nueva.',
      ),
      findsOneWidget,
    );
    await _fillPin(tester);
    expect(_confirmEnabled(tester), isFalse);

    final SaleReturnDraft committed = returnDraft();
    final FakeCorrections unseen = FakeCorrections()
      ..completed = CompletedCorrection.of(
        committed,
        SaleReturnReceipt.fromCallable(returnResponse(), draft: committed),
      );
    await tester.pumpWidget(const SizedBox());
    await _pump(tester, backend: unseen);
    expect(
      find.text(
        'Hay una corrección registrada pendiente de revisar. Abre su '
        'comprobante para continuar.',
      ),
      findsOneWidget,
    );
    await _fillPin(tester);
    expect(_confirmEnabled(tester), isFalse);
  });

  testWidgets('a session failure without a stored draft just explains', (
    WidgetTester tester,
  ) async {
    final FakeCorrections backend = FakeCorrections()
      ..replacementResults.add(const SaleSessionException());
    await _pump(tester, backend: backend);
    await _fillPin(tester);
    await _tap(tester, _key('replacement-confirm'));
    expect(
      find.text('Tu sesión cambió. Inicia sesión de nuevo para continuar.'),
      findsOneWidget,
    );
    expect(_key('replacement-retry'), findsNothing);
    expect(backend.replacementSubmits, isEmpty);
  });

  testWidgets('back returns to the sale', (WidgetTester tester) async {
    final _Harness harness = await _pump(tester);
    await _tap(tester, _key('replacement-back'));
    expect(harness.backs, 1);
  });

  for (final (Size size, double scale) in responsiveViewports) {
    testWidgets(
      'a filled replacement fits ${size.width.toInt()}px at text scale $scale',
      (WidgetTester tester) async {
        useViewport(tester, size, scale);
        await _pump(tester);
        await _fillPin(tester);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
