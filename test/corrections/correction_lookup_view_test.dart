import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/corrections/correction_draft.dart';
import 'package:lda_inventory/corrections/correction_lookup_view.dart';
import 'package:lda_inventory/corrections/correction_receipt.dart';
import 'package:lda_inventory/corrections/correction_return_form.dart';
import 'package:lda_inventory/corrections/correction_sale.dart';
import 'package:lda_inventory/corrections/sale_corrections.dart';
import 'package:lda_inventory/firebase/emulator_sale_gateway.dart';
import 'package:lda_inventory/sales/sale_cart.dart';
import 'package:lda_inventory/sales/sale_format.dart';

import '../sales/sale_fixtures.dart';
import 'correction_fixtures.dart';
import 'correction_ui_fixtures.dart' show responsiveViewports, useViewport;

const Map<String, String> _names = <String, String>{'DEMO-RIBBON': 'Ribbon'};

CorrectableSale _sale({
  String saleId = saleKey,
  Object? folio = 'NTE-3F2A-9C1B',
  int ribbonReturned = 50,
}) => parseCorrectableSale(
  lookupSaleJson(saleId: saleId, folio: folio, ribbonReturned: ribbonReturned),
);

RecentCorrectableSales _recent(List<CorrectableSale> sales) =>
    RecentCorrectableSales.fromCallable(<String, Object?>{
      'sales': <Object?>[
        for (final CorrectableSale sale in sales)
          lookupSaleJson(
            saleId: sale.saleId,
            folio: sale.folio,
            ribbonReturned: sale.lines.first.returnedScaled,
          ),
      ],
    }, query: RecentSalesQuery());

/// Records lookups and answers from queues; an empty queue answers with the
/// default sale or an empty list.
class _Backend {
  final List<Map<String, Object?>> finds = <Map<String, Object?>>[];
  int lists = 0;
  final List<Object> findResults = <Object>[];
  final List<Object> listResults = <Object>[];

  Future<CorrectableSale> find(SaleLookupQuery query) async {
    finds.add(query.toRequest());
    final Object result = findResults.isEmpty
        ? _sale()
        : findResults.removeAt(0);
    return _answer<CorrectableSale>(result);
  }

  Future<RecentCorrectableSales> listRecent() async {
    lists += 1;
    final Object result = listResults.isEmpty
        ? _recent(const <CorrectableSale>[])
        : listResults.removeAt(0);
    return _answer<RecentCorrectableSales>(result);
  }

  Future<T> _answer<T>(Object result) {
    if (result is Completer<T>) return result.future;
    if (result is T) return Future<T>.value(result as T);
    return Future<T>.error(result);
  }

  final List<SaleReturnDraft> submits = <SaleReturnDraft>[];

  SaleCorrections get corrections => SaleCorrections(
    branchId: saleBranchId,
    find: find,
    listRecent: listRecent,
    previewReturn: (SaleReturnPreviewRequest request) async =>
        SaleReturnPreview.fromCallable(
          returnPreviewJsonFor(request),
          request: request,
        ),
    submitReturn: (SaleReturnDraft draft) async {
      submits.add(draft);
      return SaleReturnReceipt.fromCallable(
        returnResponseFor(draft),
        draft: draft,
      );
    },
    previewExchange: (_) async => throw UnimplementedError(),
    submitReplacement: (_) async => throw UnimplementedError(),
    submitExchange: (_) async => throw UnimplementedError(),
    unresolvedDraft: () => null,
    unacknowledged: () => null,
    acknowledge: (_) {},
  );
}

Finder _key(String value) => find.byKey(ValueKey<String>(value));

Future<void> _pump(
  WidgetTester tester,
  _Backend backend, {
  VoidCallback? onClose,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: CorrectionLookupView(
          corrections: backend.corrections,
          productNames: _names,
          onClose: onClose ?? () {},
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> _search(WidgetTester tester, String folio) async {
  await tester.enterText(_key('correction-folio'), folio);
  await _tap(tester, _key('correction-search'));
}

void main() {
  testWidgets('recent sales show loading, then folio, date, total, payment', (
    WidgetTester tester,
  ) async {
    final _Backend backend = _Backend();
    final Completer<RecentCorrectableSales> pending =
        Completer<RecentCorrectableSales>();
    backend.listResults.add(pending);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CorrectionLookupView(
            corrections: backend.corrections,
            productNames: _names,
            onClose: () {},
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Ventas recientes (últimos 15 días)'), findsOneWidget);
    expect(_key('correction-recent-loading'), findsOneWidget);

    final CorrectableSale withFolio = _sale();
    final CorrectableSale legacy = _sale(saleId: otherSaleId, folio: null);
    pending.complete(_recent(<CorrectableSale>[withFolio, legacy]));
    await tester.pumpAndSettle();

    expect(_key('correction-recent-loading'), findsNothing);
    expect(backend.lists, 1);
    final Finder first = _key('correction-sale-$saleKey');
    expect(
      find.descendant(of: first, matching: find.text('NTE-3F2A-9C1B')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: first,
        matching: find.text(
          '${formatSaleDateTime(withFolio.createdAt.toLocal())} · Tarjeta',
        ),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: first, matching: find.text('36.50 MXN')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: _key('correction-sale-$otherSaleId'),
        matching: find.text('Venta sin folio'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('an empty recent list says so', (WidgetTester tester) async {
    await _pump(tester, _Backend());
    expect(find.text('No hay ventas recientes'), findsOneWidget);
  });

  testWidgets('a failed recent list offers a retry that reloads', (
    WidgetTester tester,
  ) async {
    final _Backend backend = _Backend()
      ..listResults.add(const SaleUncertainException())
      ..listResults.add(_recent(<CorrectableSale>[_sale()]));
    await _pump(tester, backend);
    expect(
      find.text('No se pudieron cargar las ventas recientes.'),
      findsOneWidget,
    );
    await _tap(tester, _key('correction-recent-retry'));
    expect(backend.lists, 2);
    expect(_key('correction-sale-$saleKey'), findsOneWidget);
    expect(
      find.text('No se pudieron cargar las ventas recientes.'),
      findsNothing,
    );
  });

  testWidgets('a malformed recent list is an error too', (
    WidgetTester tester,
  ) async {
    final _Backend backend = _Backend()
      ..listResults.add(const CorrectionProtocolException());
    await _pump(tester, backend);
    expect(_key('correction-recent-error'), findsOneWidget);
  });

  testWidgets('an invalid or empty folio is caught before calling', (
    WidgetTester tester,
  ) async {
    final _Backend backend = _Backend();
    await _pump(tester, backend);
    await _search(tester, 'not a folio');
    expect(
      find.text(
        'El folio no es válido. Usa el formato del ticket, '
        'por ejemplo NTE-3F2A-9C1B.',
      ),
      findsOneWidget,
    );
    await _search(tester, '   ');
    expect(find.text('Escribe el folio del ticket.'), findsOneWidget);
    expect(backend.finds, isEmpty);
  });

  testWidgets('rejections show the not-found and ambiguous messages', (
    WidgetTester tester,
  ) async {
    final _Backend backend = _Backend()
      ..findResults.add(
        const SaleRejectedException(code: 'not-found', message: 'missing'),
      )
      ..findResults.add(
        const SaleRejectedException(
          code: 'failed-precondition',
          message: 'folio is ambiguous',
          reason: 'folio-ambiguous',
        ),
      )
      ..findResults.add(
        const SaleRejectedException(
          code: 'failed-precondition',
          message: 'persisted sale is invalid',
        ),
      )
      ..findResults.add(const SaleUncertainException())
      ..findResults.add(const SaleSessionException());
    await _pump(tester, backend);

    await _search(tester, ' nte-3f2a-9c1b ');
    expect(backend.finds.single, <String, Object?>{'folio': 'NTE-3F2A-9C1B'});
    expect(
      find.text(
        'No se encontró una venta con ese folio en esta sucursal '
        '(últimos 15 días)',
      ),
      findsOneWidget,
    );

    await _search(tester, 'NTE-3F2A-9C1B');
    expect(
      find.text(
        'Hay más de una venta con ese folio. '
        'Elige la venta en la lista de ventas recientes.',
      ),
      findsOneWidget,
    );

    // Only the structured reason means ambiguous.
    await _search(tester, 'NTE-3F2A-9C1B');
    expect(
      find.text('Esta venta no se puede corregir en este momento.'),
      findsOneWidget,
    );
    expect(find.textContaining('más de una venta'), findsNothing);

    await _search(tester, 'NTE-3F2A-9C1B');
    expect(
      find.text('No se pudo buscar la venta. Intenta de nuevo.'),
      findsOneWidget,
    );

    await _search(tester, 'NTE-3F2A-9C1B');
    expect(
      find.text('Tu sesión cambió. Inicia sesión de nuevo para continuar.'),
      findsOneWidget,
    );
    expect(_key('correction-detail'), findsNothing);
  });

  testWidgets('a search is pending until it answers, then opens the detail', (
    WidgetTester tester,
  ) async {
    final _Backend backend = _Backend();
    final Completer<CorrectableSale> pending = Completer<CorrectableSale>();
    backend.findResults.add(pending);
    await _pump(tester, backend);
    await tester.enterText(_key('correction-folio'), 'NTE-3F2A-9C1B');
    await tester.tap(_key('correction-search'));
    await tester.pump();
    expect(
      tester.widget<FilledButton>(_key('correction-search')).onPressed,
      isNull,
    );
    pending.complete(_sale());
    await tester.pumpAndSettle();
    expect(_key('correction-detail'), findsOneWidget);
  });

  testWidgets('the detail shows the sale, the lines and the actions', (
    WidgetTester tester,
  ) async {
    final CorrectableSale sale = _sale(ribbonReturned: 250);
    final _Backend backend = _Backend()
      ..listResults.add(_recent(<CorrectableSale>[sale]));
    await _pump(tester, backend);
    await _tap(tester, _key('correction-sale-$saleKey'));

    expect(_key('correction-detail'), findsOneWidget);
    expect(find.text('Venta NTE-3F2A-9C1B'), findsOneWidget);
    expect(
      find.text('Fecha: ${formatSaleDateTime(sale.createdAt.toLocal())}'),
      findsOneWidget,
    );
    expect(find.text('Total: 36.50 MXN'), findsOneWidget);
    expect(find.text('Método de pago: Tarjeta'), findsOneWidget);
    expect(find.text('Factura: Con factura'), findsOneWidget);
    expect(
      find.text(
        'Corregible hasta '
        '${formatSaleDateTime(sale.correctionWindowEndsAt.toLocal())}',
      ),
      findsOneWidget,
    );

    final Finder ribbon = _key('correction-line-0');
    for (final String text in <String>[
      'Ribbon',
      'Vendido: 2.50 meter',
      'Devuelto: 2.50 meter',
      'Restante: 0.00 meter',
      'Devuelto por completo',
    ]) {
      expect(
        find.descendant(of: ribbon, matching: find.text(text)),
        findsOneWidget,
        reason: text,
      );
    }
    // Unknown to the catalog: the product ID is shown instead of a name.
    final Finder pin = _key('correction-line-1');
    for (final String text in <String>[
      'DEMO-PIN',
      'Vendido: 3 piece',
      'Devuelto: 0 piece',
      'Restante: 3 piece',
    ]) {
      expect(
        find.descendant(of: pin, matching: find.text(text)),
        findsOneWidget,
        reason: text,
      );
    }
    expect(
      find.descendant(of: pin, matching: find.text('Devuelto por completo')),
      findsNothing,
    );

    // The pin is still returnable, so every action is enabled.
    expect(find.text('Devolver'), findsOneWidget);
    expect(
      tester.widget<FilledButton>(_key('correction-action-return')).onPressed,
      isNotNull,
    );
    for (final (String key, String label) in <(String, String)>[
      ('correction-action-replace', 'Reemplazar (defecto de fábrica)'),
      ('correction-action-exchange', 'Cambiar producto'),
    ]) {
      expect(find.text(label), findsOneWidget);
      expect(tester.widget<OutlinedButton>(_key(key)).onPressed, isNotNull);
    }
    expect(find.text('Próximamente'), findsNothing);

    await _tap(tester, _key('correction-detail-back'));
    expect(_key('correction-detail'), findsNothing);
    expect(_key('correction-folio'), findsOneWidget);
  });

  testWidgets('a legacy sale detail has no folio', (WidgetTester tester) async {
    // Legacy sales have no folio to search, so they open from the list.
    final _Backend backend = _Backend()
      ..listResults.add(_recent(<CorrectableSale>[_sale(folio: null)]));
    await _pump(tester, backend);
    await _tap(tester, _key('correction-sale-$saleKey'));
    expect(
      find.descendant(
        of: _key('correction-detail'),
        matching: find.text('Venta sin folio'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('closing returns to the catalog', (WidgetTester tester) async {
    int closes = 0;
    await _pump(tester, _Backend(), onClose: () => closes += 1);
    await _tap(tester, _key('corrections-close'));
    expect(closes, 1);
  });

  testWidgets(
    'a stale search that still owns the view shows a retryable error',
    (WidgetTester tester) async {
      final _Backend backend = _Backend()
        ..findResults.add(const SaleStaleException());
      await _pump(tester, backend);
      await _search(tester, 'NTE-3F2A-9C1B');
      expect(
        find.text('No se pudo buscar la venta. Intenta de nuevo.'),
        findsOneWidget,
      );
      expect(
        tester.widget<FilledButton>(_key('correction-search')).onPressed,
        isNotNull,
      );
      await _search(tester, 'NTE-3F2A-9C1B');
      expect(_key('correction-detail'), findsOneWidget);
    },
  );

  testWidgets('a superseded search stays silent', (WidgetTester tester) async {
    final _Backend backend = _Backend();
    final Completer<CorrectableSale> pending = Completer<CorrectableSale>();
    backend
      ..findResults.add(pending)
      ..listResults.add(_recent(<CorrectableSale>[_sale()]));
    await _pump(tester, backend);
    await tester.enterText(_key('correction-folio'), 'NTE-3F2A-9C1B');
    await tester.tap(_key('correction-search'));
    await tester.pump();
    // Opening a recent sale supersedes the pending search.
    await tester.ensureVisible(_key('correction-sale-$saleKey'));
    await tester.tap(_key('correction-sale-$saleKey'));
    await tester.pump();
    pending.completeError(const SaleStaleException());
    await tester.pumpAndSettle();
    expect(_key('correction-detail'), findsOneWidget);
    await _tap(tester, _key('correction-detail-back'));
    expect(
      find.text('No se pudo buscar la venta. Intenta de nuevo.'),
      findsNothing,
    );
  });

  testWidgets('a fully returned sale cannot be returned again', (
    WidgetTester tester,
  ) async {
    final CorrectableSale sale = parseCorrectableSale(
      lookupSaleJson(ribbonReturned: 250),
    );
    final CorrectableSale done = CorrectableSale.fromLookup(<String, Object?>{
      'sale': <String, Object?>{
        ...lookupSaleJson(ribbonReturned: 250),
        'lines': <Object?>[
          (lookupSaleJson(ribbonReturned: 250)['lines']! as List<Object?>)
              .first,
          <String, Object?>{
            'lineIndex': 1,
            'soldScaled': 3,
            'returnedScaled': 3,
            'remainingScaled': 0,
          },
        ],
      },
    }, query: SaleLookupQuery.bySaleId(saleKey));
    expect(sale.hasReturnableQuantity, isTrue);
    final _Backend backend = _Backend()
      ..listResults.add(_recent(<CorrectableSale>[sale]))
      ..findResults.add(done);
    await _pump(tester, backend);
    await _search(tester, 'NTE-3F2A-9C1B');
    expect(
      tester.widget<FilledButton>(_key('correction-action-return')).onPressed,
      isNull,
    );
    // Nothing remains, so nothing can be replaced or exchanged either.
    for (final String key in <String>[
      'correction-action-replace',
      'correction-action-exchange',
    ]) {
      expect(tester.widget<OutlinedButton>(_key(key)).onPressed, isNull);
    }
  });

  testWidgets('a return shows its receipt, then the refetched sale', (
    WidgetTester tester,
  ) async {
    final _Backend backend = _Backend()
      ..listResults.add(_recent(<CorrectableSale>[_sale()]))
      ..findResults.add(const SaleUncertainException())
      ..findResults.add(_sale(ribbonReturned: 150));
    await _pump(tester, backend);
    await _tap(tester, _key('correction-sale-$saleKey'));
    await _tap(tester, _key('correction-action-return'));
    expect(_key('return-form'), findsOneWidget);

    await _tap(tester, _key('return-line-select-0'));
    await tester.enterText(_key('return-line-quantity-0'), '1');
    await _tap(tester, _key('return-reason-change-of-mind'));
    await tester.pump(returnPreviewDelay);
    await tester.pumpAndSettle();
    await _tap(tester, _key('return-confirm'));

    expect(_key('return-receipt'), findsOneWidget);
    expect(find.text('Total reembolsado: 11.60 MXN'), findsOneWidget);
    expect(backend.submits.single.branchId, saleBranchId);

    await _tap(tester, _key('return-receipt-back'));
    expect(backend.finds.single, <String, Object?>{'saleId': saleKey});
    expect(_key('correction-refresh-error'), findsOneWidget);
    expect(find.text('No se pudo actualizar la venta.'), findsOneWidget);

    await _tap(tester, _key('correction-refresh-retry'));
    expect(backend.finds, hasLength(2));
    expect(backend.finds.last, <String, Object?>{'saleId': saleKey});
    final Finder ribbon = _key('correction-line-0');
    for (final String text in <String>[
      'Vendido: 2.50 meter',
      'Devuelto: 1.50 meter',
      'Restante: 1.00 meter',
    ]) {
      expect(
        find.descendant(of: ribbon, matching: find.text(text)),
        findsOneWidget,
        reason: text,
      );
    }
  });

  testWidgets('a new search after a return reloads the recent sales', (
    WidgetTester tester,
  ) async {
    final _Backend backend = _Backend()
      ..listResults.add(_recent(<CorrectableSale>[_sale()]));
    await _pump(tester, backend);
    await _tap(tester, _key('correction-sale-$saleKey'));
    await _tap(tester, _key('correction-action-return'));
    await _tap(tester, _key('return-line-select-1'));
    await tester.enterText(_key('return-line-quantity-1'), '1');
    await _tap(tester, _key('return-reason-other'));
    await tester.pump(returnPreviewDelay);
    await tester.pumpAndSettle();
    await _tap(tester, _key('return-confirm'));
    expect(backend.lists, 1);

    await _tap(tester, _key('return-receipt-new-search'));
    expect(_key('correction-folio'), findsOneWidget);
    expect(_key('return-receipt'), findsNothing);
    expect(backend.lists, 2);
    expect(backend.finds, isEmpty);
  });

  testWidgets('back from the return form shows the same sale', (
    WidgetTester tester,
  ) async {
    final _Backend backend = _Backend()
      ..listResults.add(_recent(<CorrectableSale>[_sale()]));
    await _pump(tester, backend);
    await _tap(tester, _key('correction-sale-$saleKey'));
    await _tap(tester, _key('correction-action-return'));
    await _tap(tester, _key('return-back'));
    expect(_key('correction-detail'), findsOneWidget);
    expect(_key('return-form'), findsNothing);
  });

  test('the window length is named and drives the copy', () {
    expect(correctionWindowDays, 15);
    expect(correctionWindow, const Duration(days: correctionWindowDays));
  });

  for (final (Size size, double scale) in responsiveViewports) {
    testWidgets(
      'a found sale fits ${size.width.toInt()}px at text scale $scale',
      (WidgetTester tester) async {
        useViewport(tester, size, scale);
        await _pump(tester, _Backend());
        await _search(tester, ' nte-3f2a-9c1b ');
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('a found sale meets tap target guidelines', (
    WidgetTester tester,
  ) async {
    final SemanticsHandle semantics = tester.ensureSemantics();
    await _pump(tester, _Backend());
    await _search(tester, ' nte-3f2a-9c1b ');
    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    semantics.dispose();
  });
}
