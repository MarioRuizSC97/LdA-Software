import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/catalog/catalog_product.dart';
import 'package:lda_inventory/catalog/catalog_stock.dart';
import 'package:lda_inventory/firebase/emulator_transfer_gateway.dart';
import 'package:lda_inventory/transfers/administrator_transfer_form.dart';
import 'package:lda_inventory/transfers/transfer_draft.dart';

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

const CatalogBranchChoice _north = CatalogBranchChoice(
  branchId: 'branch-north',
  branchName: 'Norte',
);
const CatalogBranchChoice _south = CatalogBranchChoice(
  branchId: 'branch-south',
  branchName: 'Sur',
);
const CatalogBranchChoice _east = CatalogBranchChoice(
  branchId: 'branch-east',
  branchName: 'Este',
);
const List<CatalogBranchChoice> _branches = <CatalogBranchChoice>[
  _north,
  _south,
  _east,
];

/// Priced on purpose: a transfer form must never disclose price or cost.
const CatalogProduct _coffee = CatalogProduct(
  internalCode: 'PRD-COFFEE-001',
  name: 'Café',
  quantitySpec: QuantitySpec(unit: 'kg', precision: 2),
  pricing: CatalogPricing(
    listedPriceCentavos: 12900,
    currency: 'MXN',
    priceMode: 'iva-included',
    ivaTreatment: 'taxable',
    ivaRateBasisPoints: 1600,
  ),
);
const CatalogProduct _ribbon = CatalogProduct(
  internalCode: 'DEMO-RIBBON-01',
  name: 'Cinta',
  quantitySpec: QuantitySpec(unit: 'piece', precision: 0),
);
const List<CatalogProduct> _products = <CatalogProduct>[_coffee, _ribbon];

List<CatalogProduct> _manyProducts(int count) => <CatalogProduct>[
  for (int index = 0; index < count; index += 1)
    CatalogProduct(
      internalCode: 'PRD-ITEM-${1000 + index}',
      name: 'Item $index',
      quantitySpec: const QuantitySpec(unit: 'piece', precision: 0),
    ),
];

TransferDraft _draft({
  String idempotencyKey = 'key-restore-1',
  String sourceBranchId = 'branch-north',
  String destinationBranchId = 'branch-south',
  List<TransferLine>? lines,
}) => TransferDraft(
  idempotencyKey: idempotencyKey,
  sourceBranchId: sourceBranchId,
  destinationBranchId: destinationBranchId,
  lines:
      lines ??
      <TransferLine>[
        const TransferLine(
          productId: 'PRD-COFFEE-001',
          quantity: '2.50',
          quantitySpec: QuantitySpec(unit: 'kg', precision: 2),
        ),
      ],
);

/// Strict fake: answers the exact six-field callable shape and parses it with
/// the AF01 contract, so a payload that drifted can never be reported success.
TransferResult _resultFor(TransferDraft request, {bool replayed = false}) {
  final Map<String, Object?> raw = <String, Object?>{
    'transferId': request.idempotencyKey,
    'sourceBranchId': request.sourceBranchId,
    'destinationBranchId': request.destinationBranchId,
    'occurredAt': 1767225600000,
    'replayed': replayed,
    'lines': request.lines
        .map(
          (TransferLine line) => <String, Object?>{
            'productId': line.productId,
            'quantity': line.quantity,
            'quantityScaled': line.quantityScaled,
            'unit': line.quantitySpec.unit,
            'precision': line.quantitySpec.precision,
            'sourceQuantityScaled': 900000,
            'destinationQuantityScaled': line.quantityScaled,
          },
        )
        .toList(),
  };
  return TransferResult.fromCallable(raw, request: request);
}

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------

class _Backend {
  final List<TransferDraft> drafts = <TransferDraft>[];
  final List<Map<String, Object?>> payloads = <Map<String, Object?>>[];
  final List<Completer<Object?>> _replies = <Completer<Object?>>[];

  int get invocations => drafts.length;

  TransferSubmit get submit => _submit;

  Future<TransferResult> _submit(TransferDraft draft) async {
    drafts.add(draft);
    payloads.add(draft.toRequest());
    final Completer<Object?> reply = Completer<Object?>();
    _replies.add(reply);
    final Object? outcome = await reply.future;
    if (outcome is TransferResult) return outcome;
    throw outcome!;
  }

  /// Resolves the call that is currently in flight.
  void answer(Object? outcome) => _replies.last.complete(outcome);

  void succeed({bool replayed = false}) =>
      answer(_resultFor(drafts.last, replayed: replayed));
}

class _Harness {
  _Harness({
    List<CatalogBranchChoice>? branches,
    List<CatalogProduct>? products,
    this.owner = 'admin-1',
    this.initialSourceBranchId,
    this.unresolved,
    _Backend? backend,
  }) : branches = branches ?? _branches,
       products = products ?? _products,
       backend = backend ?? _Backend();

  final _Backend backend;
  List<CatalogBranchChoice> branches;
  List<CatalogProduct> products;
  String owner;
  final String? initialSourceBranchId;
  TransferDraft? unresolved;

  final List<TransferResult> completed = <TransferResult>[];
  final List<String> minted = <String>[];
  int closes = 0;
  int lookups = 0;

  /// Convenience delegates for the call that is currently in flight.
  void answer(Object? outcome) => backend.answer(outcome);

  void succeed({bool replayed = false}) => backend.succeed(replayed: replayed);

  Widget widget() => MaterialApp(
    home: Scaffold(
      body: AdministratorTransferForm(
        ownerUserId: owner,
        branches: branches,
        products: products,
        submitTransfer: backend.submit,
        unresolvedDraft: () {
          lookups += 1;
          return unresolved;
        },
        onClose: () => closes += 1,
        onCompleted: completed.add,
        createTransferId: () {
          final String key = 'key-${minted.length + 1}';
          minted.add(key);
          return key;
        },
        initialSourceBranchId: initialSourceBranchId,
      ),
    ),
  );
}

Future<_Harness> _pump(
  WidgetTester tester, {
  List<CatalogBranchChoice>? branches,
  List<CatalogProduct>? products,
  String owner = 'admin-1',
  String? initialSourceBranchId,
  TransferDraft? unresolved,
}) async {
  final _Harness harness = _Harness(
    branches: branches,
    products: products,
    owner: owner,
    initialSourceBranchId: initialSourceBranchId,
    unresolved: unresolved,
  );
  await tester.pumpWidget(harness.widget());
  await tester.pumpAndSettle();
  return harness;
}

Future<void> _repump(WidgetTester tester, _Harness harness) async {
  await tester.pumpWidget(harness.widget());
  await tester.pumpAndSettle();
}

Future<void> _unmount(WidgetTester tester) => tester.pumpWidget(
  const MaterialApp(home: Scaffold(body: SizedBox.shrink())),
);

Finder _key(String value) => find.byKey(ValueKey<String>(value));

Finder _productFields() => find.byWidgetPredicate(
  (Widget widget) =>
      widget is DropdownButtonFormField<String> &&
      (_valueKey(widget.key)?.startsWith('transfer-product-') ?? false),
);

Finder _quantities() => find.byType(TextFormField);

Finder _removes() => find.byTooltip('Quitar producto');

String? _valueKey(Key? key) => key is ValueKey<String> ? key.value : null;

Future<void> _reveal(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
}

Future<void> _tapFinder(WidgetTester tester, Finder finder) async {
  await _reveal(tester, finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> _tapKey(WidgetTester tester, String key) =>
    _tapFinder(tester, _key(key));

Future<void> _pick(WidgetTester tester, Finder field, String label) async {
  await _reveal(tester, field);
  await tester.tap(field);
  await tester.pumpAndSettle();
  final Finder option = find.text(label).last;
  await _reveal(tester, option);
  await tester.tap(option);
  await tester.pumpAndSettle();
}

Future<void> _pickBranch(WidgetTester tester, String key, String name) async =>
    _pick(tester, _key(key), name);

Future<void> _pickProduct(WidgetTester tester, int row, String name) async =>
    _pick(tester, _productFields().at(row), name);

Future<void> _enter(WidgetTester tester, int row, String text) async {
  final Finder field = _quantities().at(row);
  await _reveal(tester, field);
  await tester.enterText(field, text);
  await tester.pump();
}

Future<void> _addLine(WidgetTester tester) async {
  await _tapKey(tester, 'transfer-add-line');
}

Future<void> _fillSingleLine(
  WidgetTester tester, {
  String source = 'Norte',
  String destination = 'Sur',
  String product = 'Café',
  String quantity = '2.50',
}) async {
  await _pickBranch(tester, 'transfer-source', source);
  await _pickBranch(tester, 'transfer-destination', destination);
  await _pickProduct(tester, 0, product);
  await _enter(tester, 0, quantity);
}

Future<void> _openConfirmation(WidgetTester tester) async {
  await _tapKey(tester, 'transfer-submit');
}

/// Confirms the dialog without settling: the in-flight spinner animates
/// forever until the fake backend answers.
Future<void> _confirm(WidgetTester tester) async {
  await _reveal(tester, _key('transfer-confirm-ok'));
  await tester.tap(_key('transfer-confirm-ok'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

bool _enabled(WidgetTester tester, String key) {
  final Widget button = tester.widget(_key(key));
  if (button is FilledButton) return button.onPressed != null;
  if (button is OutlinedButton) return button.onPressed != null;
  throw StateError('no button found for $key');
}

bool _branchEditable(WidgetTester tester, String key) =>
    tester.widget<DropdownButtonFormField<String>>(_key(key)).onChanged != null;

/// A disposed controller refuses new listeners in debug builds, which proves
/// the form released it instead of only forgetting the row.
void _expectDisposed(TextEditingController controller) => expect(
  () => controller.addListener(() {}),
  throwsA(isA<FlutterError>()),
  reason: 'the line controller must be disposed',
);

void main() {
  group('form rendering', () {
    testWidgets('shows the Spanish header, both branches and one line', (
      WidgetTester tester,
    ) async {
      final _Harness harness = await _pump(tester);

      expect(find.text('Traslado entre sucursales'), findsOneWidget);
      expect(find.text('Sucursal de origen'), findsOneWidget);
      expect(find.text('Sucursal de destino'), findsOneWidget);
      expect(_productFields(), findsOneWidget);
      expect(_quantities(), findsOneWidget);
      expect(find.text('Productos: 1 de 50'), findsOneWidget);
      expect(harness.backend.invocations, 0);
      expect(harness.lookups, 1);
    });

    testWidgets('exposes header and error semantics', (
      WidgetTester tester,
    ) async {
      await _pump(tester);

      expect(
        tester
            .widget<Semantics>(_key('transfer-header-semantics'))
            .properties
            .header,
        isTrue,
      );
      expect(
        tester
            .widget<Semantics>(_key('transfer-notice-semantics'))
            .properties
            .liveRegion,
        isTrue,
      );
      expect(_key('transfer-error'), findsNothing);
    });

    testWidgets('never discloses pricing or cost data', (
      WidgetTester tester,
    ) async {
      final _Harness harness = await _pump(tester);
      await _fillSingleLine(tester);
      await _openConfirmation(tester);
      await _confirm(tester);
      harness.succeed();
      await tester.pumpAndSettle();

      expect(find.textContaining('MXN'), findsNothing);
      expect(find.textContaining('Precio'), findsNothing);
      expect(find.textContaining('Costo'), findsNothing);
      expect(harness.backend.payloads.single.keys.toList(), <String>[
        'idempotencyKey',
        'sourceBranchId',
        'destinationBranchId',
        'lines',
      ]);
    });

    testWidgets('states that the server revalidates stock', (
      WidgetTester tester,
    ) async {
      await _pump(tester);

      expect(
        find.text('El servidor verifica el stock al ejecutar el traslado.'),
        findsOneWidget,
      );
    });

    testWidgets('disables a new transfer with fewer than two branches', (
      WidgetTester tester,
    ) async {
      await _pump(tester, branches: <CatalogBranchChoice>[_north]);

      expect(
        find.text(
          'Se necesitan al menos dos sucursales para registrar un traslado.',
        ),
        findsOneWidget,
      );
      expect(_enabled(tester, 'transfer-submit'), isFalse);
    });

    testWidgets('disables a new transfer without products', (
      WidgetTester tester,
    ) async {
      await _pump(tester, products: const <CatalogProduct>[]);

      expect(
        find.text('No hay productos disponibles para trasladar.'),
        findsOneWidget,
      );
      expect(_enabled(tester, 'transfer-submit'), isFalse);
      expect(_enabled(tester, 'transfer-add-line'), isFalse);
    });

    testWidgets('preselects a source hint that exists in the catalog', (
      WidgetTester tester,
    ) async {
      await _pump(tester, initialSourceBranchId: 'branch-south');

      expect(
        tester
            .widget<DropdownButtonFormField<String>>(_key('transfer-source'))
            .initialValue,
        'branch-south',
      );
    });

    testWidgets('ignores a source hint that is not in the catalog', (
      WidgetTester tester,
    ) async {
      await _pump(tester, initialSourceBranchId: 'branch-ghost');

      expect(
        tester
            .widget<DropdownButtonFormField<String>>(_key('transfer-source'))
            .initialValue,
        isNull,
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('validation before any network call', () {
    testWidgets('refuses the same branch as source and destination', (
      WidgetTester tester,
    ) async {
      final _Harness harness = await _pump(tester);
      await _pickBranch(tester, 'transfer-source', 'Norte');
      await _pickBranch(tester, 'transfer-destination', 'Norte');
      await _pickProduct(tester, 0, 'Café');
      await _enter(tester, 0, '2');

      await _openConfirmation(tester);

      expect(
        find.text('La sucursal de origen y la de destino deben ser distintas.'),
        findsOneWidget,
      );
      expect(_key('transfer-confirm-dialog'), findsNothing);
      expect(harness.backend.invocations, 0);
    });

    testWidgets('refuses missing branch, product and quantity', (
      WidgetTester tester,
    ) async {
      final _Harness harness = await _pump(tester);

      await _openConfirmation(tester);
      expect(
        find.text('Selecciona la sucursal de origen y la de destino.'),
        findsOneWidget,
      );

      await _pickBranch(tester, 'transfer-source', 'Norte');
      await _pickBranch(tester, 'transfer-destination', 'Sur');
      await _openConfirmation(tester);
      expect(find.text('Cada línea necesita un producto.'), findsOneWidget);

      await _pickProduct(tester, 0, 'Café');
      await _openConfirmation(tester);
      expect(find.text('Cada línea necesita una cantidad.'), findsOneWidget);
      expect(harness.backend.invocations, 0);
    });

    testWidgets('offers each product only once across lines', (
      WidgetTester tester,
    ) async {
      await _pump(tester, products: _manyProducts(4));
      await _pickProduct(tester, 0, 'Item 0');
      await _addLine(tester);

      final DropdownButton<String> second = tester
          .widget<DropdownButton<String>>(
            find.descendant(
              of: _productFields().at(1),
              matching: find.byType(DropdownButton<String>),
            ),
          );
      expect(
        second.items!.map((DropdownMenuItem<String> item) => item.value),
        isNot(contains('PRD-ITEM-1000')),
      );
      expect(
        second.items!.map((DropdownMenuItem<String> item) => item.value),
        contains('PRD-ITEM-1001'),
      );
    });

    testWidgets('refuses a comma decimal instead of reinterpreting it', (
      WidgetTester tester,
    ) async {
      final _Harness harness = await _pump(tester);
      await _fillSingleLine(tester, quantity: '2,50');

      await _openConfirmation(tester);

      expect(
        find.text(
          'La cantidad debe ser un número positivo escrito con punto decimal.',
        ),
        findsOneWidget,
      );
      expect(harness.backend.invocations, 0);
    });

    testWidgets('refuses quantities above the product precision', (
      WidgetTester tester,
    ) async {
      final _Harness harness = await _pump(tester);
      await _fillSingleLine(tester, quantity: '2.505');

      await _openConfirmation(tester);
      expect(harness.backend.invocations, 0);

      await _pickProduct(tester, 0, 'Cinta');
      await _enter(tester, 0, '1.0');
      await _openConfirmation(tester);

      expect(
        find.text(
          'La cantidad debe ser un número positivo escrito con punto decimal.',
        ),
        findsOneWidget,
      );
      expect(harness.backend.invocations, 0);
    });

    testWidgets('refuses a zero quantity without a dialog', (
      WidgetTester tester,
    ) async {
      final _Harness harness = await _pump(tester);
      await _fillSingleLine(tester, quantity: '0');

      await _openConfirmation(tester);

      expect(harness.backend.invocations, 0);
      expect(_key('transfer-confirm-dialog'), findsNothing);
    });

    testWidgets('keeps the canonical dot decimal verbatim', (
      WidgetTester tester,
    ) async {
      final _Harness harness = await _pump(tester);
      await _fillSingleLine(tester, quantity: '2.50');

      await _openConfirmation(tester);
      expect(find.text('PRD-COFFEE-001: 2.50 kg'), findsOneWidget);
      await _confirm(tester);

      final Map<String, Object?> line =
          (harness.backend.payloads.single['lines']! as List<Object?>).single
              as Map<String, Object?>;
      expect(line, <String, Object?>{
        'productId': 'PRD-COFFEE-001',
        'quantity': '2.50',
      });
      expect(harness.backend.drafts.single.lines.single.quantityScaled, 250);
    });

    testWidgets('refuses a quantity beyond safe integer bounds', (
      WidgetTester tester,
    ) async {
      final _Harness harness = await _pump(tester);
      await _fillSingleLine(
        tester,
        product: 'Cinta',
        quantity: '9007199254740992',
      );

      await _openConfirmation(tester);

      expect(find.text('La cantidad es demasiado grande.'), findsOneWidget);
      expect(harness.backend.invocations, 0);
    });

    testWidgets('shows the unit and precision helper for every line', (
      WidgetTester tester,
    ) async {
      await _pump(tester);
      expect(
        find.text('Selecciona un producto para ver la unidad.'),
        findsOneWidget,
      );

      await _pickProduct(tester, 0, 'Café');
      expect(find.text('Unidad: kg (precisión 2)'), findsOneWidget);
      expect(find.text('Hasta 2 decimales.'), findsOneWidget);

      await _pickProduct(tester, 0, 'Cinta');
      expect(find.text('Unidad: piece (precisión 0)'), findsOneWidget);
      expect(find.text('Solo números enteros.'), findsOneWidget);
    });

    testWidgets('stops at fifty lines', (WidgetTester tester) async {
      await _pump(tester, products: _manyProducts(51));

      for (int index = 1; index < transferLineLimit; index += 1) {
        await _addLine(tester);
      }

      expect(find.text('Productos: 50 de 50'), findsOneWidget);
      expect(_enabled(tester, 'transfer-add-line'), isFalse);
      expect(find.text('Máximo 50 productos por traslado.'), findsOneWidget);
    });

    testWidgets('does not add more lines than available products', (
      WidgetTester tester,
    ) async {
      await _pump(tester);

      await _addLine(tester);

      expect(find.text('Productos: 2 de 50'), findsOneWidget);
      expect(_enabled(tester, 'transfer-add-line'), isFalse);
    });

    testWidgets('keeps row identity when an earlier row is removed', (
      WidgetTester tester,
    ) async {
      await _pump(tester, products: _manyProducts(4));
      await _enter(tester, 0, '1.50');
      await _addLine(tester);
      await _enter(tester, 1, '2.50');
      final List<String?> before = tester
          .widgetList<TextFormField>(_quantities())
          .map((TextFormField field) => _valueKey(field.key))
          .toList();

      await _tapFinder(tester, _removes().first);

      final List<String?> after = tester
          .widgetList<TextFormField>(_quantities())
          .map((TextFormField field) => _valueKey(field.key))
          .toList();
      expect(after, before.sublist(1));
      expect(
        tester.widget<TextFormField>(_quantities().first).controller!.text,
        '2.50',
      );
    });

    testWidgets('disposes the controller of a removed line', (
      WidgetTester tester,
    ) async {
      await _pump(tester, products: _manyProducts(4));
      await _addLine(tester);
      final TextEditingController dropped = tester
          .widget<TextFormField>(_quantities().first)
          .controller!;

      await _tapFinder(tester, _removes().first);

      _expectDisposed(dropped);
      expect(tester.takeException(), isNull);
    });

    testWidgets('disposes every controller when the form unmounts', (
      WidgetTester tester,
    ) async {
      await _pump(tester, products: _manyProducts(4));
      await _addLine(tester);
      final List<TextEditingController> controllers = tester
          .widgetList<TextFormField>(_quantities())
          .map((TextFormField field) => field.controller!)
          .toList();

      await _unmount(tester);
      await tester.pumpAndSettle();

      controllers.forEach(_expectDisposed);
      expect(tester.takeException(), isNull);
    });
  });

  group('confirmation freezes the payload', () {
    testWidgets('shows one branch pair plus the frozen lines', (
      WidgetTester tester,
    ) async {
      final _Harness harness = await _pump(tester);
      await _fillSingleLine(tester);

      await _openConfirmation(tester);

      expect(_key('transfer-confirm-dialog'), findsOneWidget);
      expect(find.text('De: Norte'), findsOneWidget);
      expect(find.text('Para: Sur'), findsOneWidget);
      expect(find.text('PRD-COFFEE-001: 2.50 kg'), findsOneWidget);
      expect(harness.backend.invocations, 0);
    });

    testWidgets('sends exactly the four server fields', (
      WidgetTester tester,
    ) async {
      final _Harness harness = await _pump(tester);
      await _fillSingleLine(tester);
      await _openConfirmation(tester);
      await _confirm(tester);

      final Map<String, Object?> payload = harness.backend.payloads.single;
      expect(payload.keys.toSet(), <String>{
        'idempotencyKey',
        'sourceBranchId',
        'destinationBranchId',
        'lines',
      });
      final Map<String, Object?> line =
          (payload['lines']! as List<Object?>).single as Map<String, Object?>;
      expect(line.keys.toSet(), <String>{'productId', 'quantity'});
      expect(payload['idempotencyKey'], 'key-1');
    });

    testWidgets('cancelling invokes nothing and allows a new operation', (
      WidgetTester tester,
    ) async {
      final _Harness harness = await _pump(tester);
      await _fillSingleLine(tester);
      await _openConfirmation(tester);

      await _tapKey(tester, 'transfer-confirm-cancel');

      expect(harness.backend.invocations, 0);
      expect(harness.minted, <String>['key-1']);

      await _enter(tester, 0, '3.50');
      await _openConfirmation(tester);
      expect(find.text('PRD-COFFEE-001: 3.50 kg'), findsOneWidget);
      await _confirm(tester);

      expect(harness.backend.invocations, 1);
      expect(harness.backend.drafts.single.idempotencyKey, 'key-2');
      expect(harness.minted, <String>['key-1', 'key-2']);
    });

    testWidgets('a double tap opens only one dialog', (
      WidgetTester tester,
    ) async {
      await _pump(tester);
      await _fillSingleLine(tester);

      await _reveal(tester, _key('transfer-submit'));
      await tester.tap(_key('transfer-submit'));
      await tester.pump();
      // The open modal barrier absorbs the second click, so the guard is the
      // dialog itself plus the _dialogOpen flag in the form.
      await tester.tap(_key('transfer-submit'), warnIfMissed: false);
      await tester.pumpAndSettle();

      expect(_key('transfer-confirm-dialog'), findsOneWidget);
    });

    testWidgets('a double tap on confirm invokes once', (
      WidgetTester tester,
    ) async {
      final _Harness harness = await _pump(tester);
      await _fillSingleLine(tester);
      await _openConfirmation(tester);

      await _reveal(tester, _key('transfer-confirm-ok'));
      await tester.tap(_key('transfer-confirm-ok'));
      await tester.pump();
      // The pop already absorbed the answer, so this click cannot reach it.
      await tester.tap(_key('transfer-confirm-ok'), warnIfMissed: false);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(harness.backend.invocations, 1);
    });

    testWidgets('locks edits and closing while the request is in flight', (
      WidgetTester tester,
    ) async {
      await _pump(tester);
      await _fillSingleLine(tester);
      await _openConfirmation(tester);
      await _confirm(tester);

      expect(_key('transfer-spinner'), findsOneWidget);
      expect(
        tester.widget<Semantics>(_key('transfer-spinner')).properties.label,
        contains('envío'),
      );
      expect(_enabled(tester, 'transfer-submit'), isFalse);
      expect(_enabled(tester, 'transfer-close'), isFalse);
      expect(_enabled(tester, 'transfer-add-line'), isFalse);
      expect(_branchEditable(tester, 'transfer-source'), isFalse);
      expect(_branchEditable(tester, 'transfer-destination'), isFalse);
      expect(
        tester.widget<TextFormField>(_quantities().first).enabled,
        isFalse,
      );
      expect(_removes(), findsNothing);
    });

    testWidgets('never vetoes a quantity against cached stock', (
      WidgetTester tester,
    ) async {
      final _Harness harness = await _pump(tester);
      await _fillSingleLine(tester, quantity: '500.00');
      await _openConfirmation(tester);
      await _confirm(tester);

      expect(harness.backend.invocations, 1);
      expect(harness.backend.payloads.single['lines'], hasLength(1));
      harness.succeed();
      await tester.pumpAndSettle();
      expect(harness.completed, hasLength(1));
    });
  });

  group('settled answers', () {
    testWidgets('success calls onCompleted once and shows a banner', (
      WidgetTester tester,
    ) async {
      final _Harness harness = await _pump(tester);
      await _fillSingleLine(tester);
      await _openConfirmation(tester);
      await _confirm(tester);

      harness.succeed();
      await tester.pumpAndSettle();

      expect(harness.completed, hasLength(1));
      expect(harness.completed.single.replayed, isFalse);
      expect(find.text('Traslado registrado correctamente.'), findsOneWidget);
      expect(_quantities(), findsOneWidget);
      expect(
        tester.widget<TextFormField>(_quantities().first).controller!.text,
        isEmpty,
      );
    });

    testWidgets('a replay is announced distinctly', (
      WidgetTester tester,
    ) async {
      final _Harness harness = await _pump(tester);
      await _fillSingleLine(tester);
      await _openConfirmation(tester);
      await _confirm(tester);

      harness.succeed(replayed: true);
      await tester.pumpAndSettle();

      expect(
        find.text(
          'El traslado ya estaba registrado; el servidor devolvió el recibo '
          'original.',
        ),
        findsOneWidget,
      );
      expect(find.text('Traslado registrado correctamente.'), findsNothing);
      expect(harness.completed, hasLength(1));
    });

    testWidgets('a new confirmed operation mints a new key', (
      WidgetTester tester,
    ) async {
      final _Harness harness = await _pump(tester);
      await _fillSingleLine(tester);
      await _openConfirmation(tester);
      await _confirm(tester);
      harness.succeed();
      await tester.pumpAndSettle();

      await _pickBranch(tester, 'transfer-destination', 'Este');
      await _pickProduct(tester, 0, 'Café');
      await _enter(tester, 0, '4.00');
      await _openConfirmation(tester);
      expect(find.text('De: Norte'), findsOneWidget);
      expect(find.text('Para: Este'), findsOneWidget);
      await _confirm(tester);
      harness.succeed();
      await tester.pumpAndSettle();

      expect(harness.backend.invocations, 2);
      expect(harness.backend.drafts.first.idempotencyKey, 'key-1');
      expect(harness.backend.drafts.last.idempotencyKey, 'key-2');
      expect(harness.completed, hasLength(2));
    });

    testWidgets('a deterministic refusal is translated and unlocks editing', (
      WidgetTester tester,
    ) async {
      final _Harness harness = await _pump(tester);
      await _fillSingleLine(tester);
      await _openConfirmation(tester);
      await _confirm(tester);

      harness.answer(const TransferRejectedException(code: 'invalid-argument'));
      await tester.pumpAndSettle();

      expect(
        find.text('El servidor rechazó los datos del traslado.'),
        findsOneWidget,
      );
      expect(find.textContaining('invalid-argument'), findsNothing);
      expect(harness.completed, isEmpty);
      expect(_enabled(tester, 'transfer-submit'), isTrue);
      expect(_branchEditable(tester, 'transfer-source'), isTrue);

      await _openConfirmation(tester);
      await _confirm(tester);
      expect(harness.backend.invocations, 2);
      expect(harness.backend.drafts.last.idempotencyKey, 'key-2');
    });

    testWidgets('every refusal code has its own Spanish wording', (
      WidgetTester tester,
    ) async {
      const Map<String, String> messages = <String, String>{
        'unauthenticated': 'Tu sesión expiró. Inicia sesión para continuar.',
        'permission-denied': 'No tienes permiso para registrar traslados.',
        'invalid-argument': 'El servidor rechazó los datos del traslado.',
        'not-found': 'La sucursal o el producto ya no existen.',
        'failed-precondition':
            'La sucursal no cumple las condiciones para este traslado.',
        'out-of-range': 'Algún valor del traslado está fuera de los límites.',
        'already-exists': 'Este traslado ya existe.',
      };
      for (final MapEntry<String, String> entry in messages.entries) {
        final _Harness harness = await _pump(tester);
        await _fillSingleLine(tester);
        await _openConfirmation(tester);
        await _confirm(tester);

        harness.answer(TransferRejectedException(code: entry.key));
        await tester.pumpAndSettle();

        expect(find.text(entry.value), findsOneWidget, reason: entry.key);
        expect(find.textContaining(entry.key), findsNothing, reason: entry.key);
        expect(harness.completed, isEmpty, reason: entry.key);
        expect(_enabled(tester, 'transfer-submit'), isTrue, reason: entry.key);
      }
    });

    testWidgets('a session change closes and blocks further submissions', (
      WidgetTester tester,
    ) async {
      final _Harness harness = await _pump(tester);
      await _fillSingleLine(tester);
      await _openConfirmation(tester);
      await _confirm(tester);

      harness.answer(const TransferSessionException());
      await tester.pumpAndSettle();

      expect(harness.closes, 1);
      expect(harness.completed, isEmpty);
      expect(_enabled(tester, 'transfer-submit'), isFalse);

      await _tapKey(tester, 'transfer-submit');
      expect(harness.backend.invocations, 1);
      expect(_key('transfer-confirm-dialog'), findsNothing);
    });
  });

  group('unknown outcomes keep the frozen request', () {
    testWidgets('uncertain retries the identical key and payload', (
      WidgetTester tester,
    ) async {
      final _Harness harness = await _pump(tester);
      await _fillSingleLine(tester);
      await _openConfirmation(tester);
      await _confirm(tester);

      harness.answer(const TransferUncertainException());
      await tester.pumpAndSettle();

      expect(
        find.text(
          'No se pudo confirmar el resultado. Reintenta el mismo envío antes '
          'de editar.',
        ),
        findsOneWidget,
      );
      expect(find.text('Reintentar mismo envío'), findsOneWidget);
      expect(_enabled(tester, 'transfer-submit'), isTrue);
      expect(_branchEditable(tester, 'transfer-source'), isFalse);
      expect(
        tester.widget<TextFormField>(_quantities().first).enabled,
        isFalse,
      );
      expect(_removes(), findsNothing);

      await _reveal(tester, _key('transfer-submit'));
      await tester.tap(_key('transfer-submit'));
      await tester.pump();
      harness.answer(const TransferUncertainException());
      await tester.pumpAndSettle();
      await _reveal(tester, _key('transfer-submit'));
      await tester.tap(_key('transfer-submit'));
      await tester.pump();
      harness.succeed();
      await tester.pumpAndSettle();

      expect(harness.backend.invocations, 3);
      expect(harness.minted, <String>['key-1']);
      expect(
        harness.backend.drafts.map((TransferDraft d) => d.idempotencyKey),
        <String>['key-1', 'key-1', 'key-1'],
      );
      expect(harness.backend.payloads[1], harness.backend.payloads[0]);
      expect(harness.backend.payloads[2], harness.backend.payloads[0]);
      expect(harness.completed, hasLength(1));
    });

    testWidgets('catalog updates cannot rewrite an unresolved payload', (
      WidgetTester tester,
    ) async {
      final _Harness harness = await _pump(tester);
      await _fillSingleLine(tester);
      await _openConfirmation(tester);
      await _confirm(tester);
      harness.answer(const TransferUncertainException());
      await tester.pumpAndSettle();

      harness.branches = <CatalogBranchChoice>[_east];
      harness.products = _manyProducts(3);
      await _repump(tester, harness);

      expect(
        tester
            .widget<DropdownButtonFormField<String>>(_key('transfer-source'))
            .initialValue,
        'branch-north',
      );
      expect(find.text('branch-north'), findsWidgets);
      expect(find.text('PRD-COFFEE-001'), findsWidgets);

      await _reveal(tester, _key('transfer-submit'));
      await tester.tap(_key('transfer-submit'));
      await tester.pump();
      harness.succeed();
      await tester.pumpAndSettle();

      expect(harness.backend.invocations, 2);
      expect(harness.backend.payloads.last, harness.backend.payloads.first);
      expect(harness.completed, hasLength(1));
    });

    testWidgets('an unexpected error after invoke is treated as unknown', (
      WidgetTester tester,
    ) async {
      final _Harness harness = await _pump(tester);
      await _fillSingleLine(tester);
      await _openConfirmation(tester);
      await _confirm(tester);

      harness.answer(StateError('transport exploded'));
      await tester.pumpAndSettle();

      expect(harness.completed, isEmpty);
      expect(find.text('Reintentar mismo envío'), findsOneWidget);
      expect(
        find.text(
          'No se pudo confirmar el resultado. Reintenta el mismo envío antes '
          'de editar.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('a same-key refusal prefers the stored draft on retry', (
      WidgetTester tester,
    ) async {
      final _Harness harness = await _pump(tester);
      await _fillSingleLine(tester);
      await _openConfirmation(tester);
      await _confirm(tester);
      final TransferDraft frozen = harness.backend.drafts.single;

      harness.answer(const TransferUnresolvedException());
      await tester.pumpAndSettle();
      harness.unresolved = frozen;

      await _reveal(tester, _key('transfer-submit'));
      await tester.tap(_key('transfer-submit'));
      await tester.pump();
      harness.succeed();
      await tester.pumpAndSettle();

      expect(harness.backend.invocations, 2);
      expect(harness.backend.drafts.last, frozen);
      expect(harness.backend.payloads.last, harness.backend.payloads.first);
      expect(harness.completed, hasLength(1));
    });

    testWidgets('a stale answer is ignored and never reported success', (
      WidgetTester tester,
    ) async {
      final _Harness harness = await _pump(tester);
      await _fillSingleLine(tester);
      await _openConfirmation(tester);
      await _confirm(tester);

      harness.answer(const TransferStaleException());
      await tester.pumpAndSettle();

      expect(harness.completed, isEmpty);
      expect(find.text('Traslado registrado correctamente.'), findsNothing);
      expect(find.text('Reintentar mismo envío'), findsOneWidget);
    });

    testWidgets('closing while unknown keeps the operation for a reopen', (
      WidgetTester tester,
    ) async {
      final _Harness harness = await _pump(tester);
      await _fillSingleLine(tester);
      await _openConfirmation(tester);
      await _confirm(tester);
      harness.answer(const TransferUncertainException());
      await tester.pumpAndSettle();

      expect(_enabled(tester, 'transfer-close'), isTrue);
      await _tapKey(tester, 'transfer-close');

      expect(harness.closes, 1);
    });

    testWidgets('a reopen restores the stored draft without minting a key', (
      WidgetTester tester,
    ) async {
      final TransferDraft stored = _draft();
      final _Harness harness = await _pump(tester, unresolved: stored);

      expect(harness.lookups, 1);
      expect(harness.minted, isEmpty);
      expect(find.text('Reintentar mismo envío'), findsOneWidget);
      expect(_key('transfer-uncertain'), findsOneWidget);
      expect(
        tester
            .widget<DropdownButtonFormField<String>>(_key('transfer-source'))
            .initialValue,
        'branch-north',
      );
      expect(
        tester.widget<TextFormField>(_quantities().first).controller!.text,
        '2.50',
      );

      await _reveal(tester, _key('transfer-submit'));
      await tester.tap(_key('transfer-submit'));
      await tester.pump();
      harness.succeed();
      await tester.pumpAndSettle();

      expect(harness.backend.payloads.single, stored.toRequest());
      expect(harness.completed, hasLength(1));
    });

    testWidgets('a restored draft survives a catalog that lost its entries', (
      WidgetTester tester,
    ) async {
      final TransferDraft stored = _draft(
        sourceBranchId: 'branch-gone',
        lines: const <TransferLine>[
          TransferLine(
            productId: 'PRD-GHOST-0001',
            quantity: '3.25',
            quantitySpec: QuantitySpec(unit: 'l', precision: 2),
          ),
        ],
      );
      final _Harness harness = await _pump(
        tester,
        branches: <CatalogBranchChoice>[_south, _east],
        products: _manyProducts(2),
        unresolved: stored,
      );

      expect(find.text('branch-gone'), findsWidgets);
      expect(find.text('PRD-GHOST-0001'), findsWidgets);
      expect(find.text('Unidad: l (precisión 2)'), findsOneWidget);
      expect(
        tester.widget<TextFormField>(_quantities().first).controller!.text,
        '3.25',
      );
      expect(tester.takeException(), isNull);

      await _reveal(tester, _key('transfer-submit'));
      await tester.tap(_key('transfer-submit'));
      await tester.pump();
      harness.succeed();
      await tester.pumpAndSettle();

      expect(harness.backend.payloads.single, stored.toRequest());
    });
  });

  group('owner and lifecycle invalidation', () {
    testWidgets('a late answer after an owner change is discarded', (
      WidgetTester tester,
    ) async {
      final _Harness harness = await _pump(tester);
      await _fillSingleLine(tester);
      await _openConfirmation(tester);
      await _confirm(tester);

      harness.owner = 'admin-2';
      await _repump(tester, harness);

      harness.answer(_resultFor(harness.backend.drafts.first));
      await tester.pumpAndSettle();

      expect(harness.completed, isEmpty);
      expect(find.text('Traslado registrado correctamente.'), findsNothing);
      expect(_key('transfer-spinner'), findsNothing);
      expect(
        tester
            .widget<DropdownButtonFormField<String>>(_key('transfer-source'))
            .initialValue,
        isNull,
      );
      expect(harness.minted, <String>['key-1']);
    });

    testWidgets('a late answer after unmount is discarded', (
      WidgetTester tester,
    ) async {
      final _Harness harness = await _pump(tester);
      await _fillSingleLine(tester);
      await _openConfirmation(tester);
      await _confirm(tester);

      await _unmount(tester);
      harness.succeed();
      await tester.pumpAndSettle();

      expect(harness.completed, isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the default key factory mints a canonical uuid', (
      WidgetTester tester,
    ) async {
      final _Backend backend = _Backend();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AdministratorTransferForm(
              ownerUserId: 'admin-1',
              branches: _branches,
              products: _products,
              submitTransfer: backend.submit,
              unresolvedDraft: () => null,
              onClose: () {},
              onCompleted: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await _fillSingleLine(tester);
      await _openConfirmation(tester);
      await _confirm(tester);

      expect(
        backend.drafts.single.idempotencyKey,
        matches(
          RegExp(
            r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-'
            r'[0-9a-f]{12}$',
          ),
        ),
      );
    });
  });

  group('responsive layout', () {
    testWidgets('fits 320px at text scale 1.3 with the keyboard open', (
      WidgetTester tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(320, 480));
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      tester.view.viewInsets = const FakeViewPadding(bottom: 220);
      addTearDown(() {
        tester.view.resetViewInsets();
        tester.platformDispatcher.clearTextScaleFactorTestValue();
        tester.binding.setSurfaceSize(null);
      });

      await _pump(tester);
      await _fillSingleLine(tester);
      await _addLine(tester);
      await _pickProduct(tester, 1, 'Cinta');
      await _enter(tester, 1, '3');
      await tester.dragUntilVisible(
        _key('transfer-submit'),
        find.byType(SingleChildScrollView).first,
        const Offset(0, -40),
      );
      await _openConfirmation(tester);

      expect(find.text('Traslado entre sucursales'), findsOneWidget);
      expect(_key('transfer-confirm-dialog'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('stays readable on a wide viewport', (
      WidgetTester tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1200, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await _pump(tester);
      await _fillSingleLine(tester);
      await _openConfirmation(tester);

      expect(
        tester
            .widget<ConstrainedBox>(_key('transfer-content'))
            .constraints
            .maxWidth,
        560,
      );
      expect(
        tester.getRect(_key('transfer-content')).width,
        lessThanOrEqualTo(560),
      );
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('the transfer form meets tap target guidelines', (
    WidgetTester tester,
  ) async {
    final SemanticsHandle semantics = tester.ensureSemantics();
    await _pump(tester);
    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    semantics.dispose();
  });
}
