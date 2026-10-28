import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/catalog/catalog_product.dart';
import 'package:lda_inventory/catalog/catalog_stock.dart';
import 'package:lda_inventory/transfers/administrator_transfer_form.dart';
import 'package:lda_inventory/transfers/transfer_draft.dart';

import '../support/viewport.dart';

const List<CatalogBranchChoice> _branches = <CatalogBranchChoice>[
  CatalogBranchChoice(branchId: 'branch-north', branchName: 'Norte'),
  CatalogBranchChoice(branchId: 'branch-south', branchName: 'Sur'),
];
const List<CatalogProduct> _products = <CatalogProduct>[
  CatalogProduct(
    internalCode: 'PRD-COFFEE-001',
    name: 'Café',
    quantitySpec: QuantitySpec(unit: 'kg', precision: 2),
  ),
  CatalogProduct(
    internalCode: 'DEMO-RIBBON-01',
    name: 'Cinta',
    quantitySpec: QuantitySpec(unit: 'piece', precision: 0),
  ),
];

Finder _key(String value) => find.byKey(ValueKey<String>(value));

Future<void> _pump(
  WidgetTester tester,
  Size size, {
  TransferDraft? unresolved,
  bool disableAnimations = false,
  Map<String, List<CatalogHolding>>? holdingsByProduct,
  double textScale = 1,
  TransferSubmit? submitTransfer,
}) async {
  useViewport(tester, size);
  await tester.pumpWidget(
    MaterialApp(
      builder: (BuildContext context, Widget? child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          disableAnimations: disableAnimations,
          textScaler: TextScaler.linear(textScale),
        ),
        child: child!,
      ),
      home: Scaffold(
        body: AdministratorTransferForm(
          ownerUserId: 'admin-1',
          branches: _branches,
          products: _products,
          holdingsByProduct: holdingsByProduct,
          submitTransfer: submitTransfer ?? (_) => throw UnimplementedError(),
          unresolvedDraft: () => unresolved,
          onClose: () {},
          onCompleted: (_) {},
          createTransferId: () => 'key-1',
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _pick(WidgetTester tester, Finder field, String label) async {
  await tester.ensureVisible(field);
  await tester.pumpAndSettle();
  await tester.tap(field);
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

Future<void> _fillLine(
  WidgetTester tester,
  int row,
  String product,
  String quantity,
) async {
  await _pick(
    tester,
    find
        .byWidgetPredicate(
          (Widget w) =>
              w is DropdownButtonFormField<String> &&
              w.key is ValueKey<String> &&
              (w.key! as ValueKey<String>).value.startsWith(
                'transfer-product-',
              ),
        )
        .at(row),
    product,
  );
  final Finder field = find.byType(TextFormField).at(row);
  await tester.ensureVisible(field);
  await tester.enterText(field, quantity);
  await tester.pump();
}

const Map<String, List<CatalogHolding>> _holdings =
    <String, List<CatalogHolding>>{
      'PRD-COFFEE-001': <CatalogHolding>[
        CatalogHolding(branchId: 'branch-north', quantityScaled: 1234),
        CatalogHolding(branchId: 'branch-south', quantityScaled: 567),
      ],
      'DEMO-RIBBON-01': <CatalogHolding>[
        CatalogHolding(branchId: 'branch-north', quantityScaled: 8),
        CatalogHolding(branchId: 'branch-south', quantityScaled: 0),
      ],
    };

Future<void> _openConfirmation(WidgetTester tester, String quantity) async {
  await _pick(tester, _key('transfer-source'), 'Norte');
  await _pick(tester, _key('transfer-destination'), 'Sur');
  await _fillLine(tester, 0, 'Café', quantity);
  await tester.ensureVisible(_key('transfer-submit'));
  await tester.tap(_key('transfer-submit'));
  await tester.pumpAndSettle();
}

const String _stockWarning =
    'Revisa las existencias en origen de: Café. '
    'La cantidad supera lo registrado o no hay entrada registrada. '
    'Puedes continuar con el envío.';

void main() {
  testWidgets('wide: source stock heading preserves stock lines and fallback', (
    tester,
  ) async {
    await _pump(
      tester,
      const Size(1200, 800),
      holdingsByProduct: <String, List<CatalogHolding>>{
        'PRD-COFFEE-001': _holdings['PRD-COFFEE-001']!,
      },
      unresolved: TransferDraft(
        idempotencyKey: 'stock-heading',
        sourceBranchId: 'branch-north',
        destinationBranchId: 'branch-south',
        lines: const <TransferLine>[
          TransferLine(
            productId: 'PRD-COFFEE-001',
            quantity: '1',
            quantitySpec: QuantitySpec(unit: 'kg', precision: 2),
          ),
          TransferLine(
            productId: 'DEMO-RIBBON-01',
            quantity: '2',
            quantitySpec: QuantitySpec(unit: 'piece', precision: 0),
          ),
        ],
      ),
    );
    expect(find.text('Existencias en sucursal origen'), findsOneWidget);
    expect(find.text('Existencias en origen'), findsNothing);
    final List<String?> railLines = tester
        .widgetList<Text>(
          find.descendant(
            of: _key('transfer-context'),
            matching: find.byType(Text),
          ),
        )
        .map((Text text) => text.data)
        .toList();
    expect(railLines, <String>[
      'Resumen del traslado',
      'Origen: Norte',
      'Destino: Sur',
      'Productos: 2',
      'Café: 1.00 kg',
      'Cinta: 2 piece',
      'Existencias en sucursal origen',
      'Café: 12.34 kg',
      'Cinta: Sin entrada registrada',
    ]);
    expect(tester.takeException(), isNull);
  });

  for (final String quantity in <String>['1.25', '12.34']) {
    testWidgets(
      'confirmation shows source stock without warning for $quantity',
      (tester) async {
        await _pump(tester, const Size(400, 800), holdingsByProduct: _holdings);
        await _openConfirmation(tester, quantity);
        expect(
          tester.widget<Text>(_key('transfer-confirm-line-0')).data,
          'Café: $quantity kg · Origen: 12.34 kg',
        );
        expect(
          find.textContaining('Revisa las existencias en origen de:'),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final double width in <double>[400, 601, 1200]) {
    testWidgets('confirmation warns without blocking submit at $width', (
      tester,
    ) async {
      TransferDraft? submitted;
      await _pump(
        tester,
        Size(width, 800),
        holdingsByProduct: _holdings,
        textScale: 2,
        submitTransfer: (draft) async {
          submitted = draft;
          throw StateError('test submission');
        },
      );
      await _openConfirmation(tester, '12.35');
      expect(
        tester.widget<Text>(_key('transfer-confirm-line-0')).data,
        'Café: 12.35 kg · Origen: 12.34 kg',
      );
      expect(find.text(_stockWarning), findsOneWidget);
      expect(submitted, isNull);
      expect(
        tester.widget<FilledButton>(_key('transfer-confirm-ok')).onPressed,
        isNotNull,
      );
      expect(find.text('Confirmar y enviar'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(_key('transfer-confirm-ok'));
      await tester.tap(_key('transfer-confirm-ok'));
      await tester.pumpAndSettle();
      expect(submitted, isNotNull);
      expect(submitted!.sourceBranchId, 'branch-north');
      expect(submitted!.destinationBranchId, 'branch-south');
      expect(submitted!.lines.single.productId, 'PRD-COFFEE-001');
      expect(submitted!.lines.single.quantity, '12.35');
      expect(_key('transfer-confirm-dialog'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('confirmation warns for missing source holding, not zero', (
    tester,
  ) async {
    await _pump(
      tester,
      const Size(400, 800),
      holdingsByProduct: const <String, List<CatalogHolding>>{
        'PRD-COFFEE-001': <CatalogHolding>[
          CatalogHolding(branchId: 'branch-south', quantityScaled: 9999),
        ],
      },
    );
    await _openConfirmation(tester, '1');
    expect(
      tester.widget<Text>(_key('transfer-confirm-line-0')).data,
      'Café: 1 kg · Origen: Sin entrada registrada',
    );
    expect(find.text(_stockWarning), findsOneWidget);
    expect(
      tester.widget<FilledButton>(_key('transfer-confirm-ok')).onPressed,
      isNotNull,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('confirmation without holdings retains its original content', (
    tester,
  ) async {
    await _pump(tester, const Size(400, 800));
    await _openConfirmation(tester, '1');
    expect(
      tester.widget<Text>(_key('transfer-confirm-line-0')).data,
      'Café: 1 kg',
    );
    expect(find.textContaining('Origen:'), findsNothing);
    expect(find.textContaining('Sin entrada registrada'), findsNothing);
    expect(
      find.textContaining('Revisa las existencias en origen de:'),
      findsNothing,
    );
    expect(find.text('Confirmar traslado'), findsOneWidget);
    expect(find.text('Cancelar'), findsOneWidget);
    expect(
      tester.widget<FilledButton>(_key('transfer-confirm-ok')).onPressed,
      isNotNull,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('source stock follows branches and selected rows', (
    tester,
  ) async {
    await _pump(tester, const Size(1200, 800), holdingsByProduct: _holdings);
    await _fillLine(tester, 0, 'Café', '');
    expect(find.text('Existencias en sucursal origen'), findsNothing);
    await _pick(tester, _key('transfer-source'), 'Norte');
    expect(find.text('Existencias en sucursal origen'), findsOneWidget);
    expect(find.text('Café: 12.34 kg'), findsOneWidget);
    await _pick(tester, _key('transfer-source'), 'Sur');
    expect(find.text('Café: 5.67 kg'), findsOneWidget);
    expect(find.text('Café: 12.34 kg'), findsNothing);
    await tester.ensureVisible(_key('transfer-add-line'));
    await tester.tap(_key('transfer-add-line'));
    await tester.pumpAndSettle();
    await _fillLine(tester, 1, 'Cinta', '');
    expect(find.text('Cinta: 0 piece'), findsOneWidget);
    await _pick(tester, _key('transfer-source'), 'Norte');
    expect(find.text('Cinta: 8 piece'), findsOneWidget);
    await tester.ensureVisible(_key('transfer-remove-1'));
    await tester.tap(_key('transfer-remove-1'));
    await tester.pumpAndSettle();
    expect(find.text('Café: 12.34 kg'), findsNothing);
    expect(find.text('Cinta: 8 piece'), findsOneWidget);
    await _fillLine(tester, 0, 'Café', '');
    expect(find.text('Cinta: 8 piece'), findsNothing);
    expect(find.text('Café: 12.34 kg'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('missing holding is not represented as zero', (tester) async {
    await _pump(
      tester,
      const Size(1200, 800),
      holdingsByProduct: const <String, List<CatalogHolding>>{},
    );
    await _pick(tester, _key('transfer-source'), 'Norte');
    expect(find.text('Existencias en sucursal origen'), findsNothing);
    await _fillLine(tester, 0, 'Café', '');
    expect(find.text('Café: Sin entrada registrada'), findsOneWidget);
    expect(find.text('Café: 0.00 kg'), findsNothing);
  });

  testWidgets('without holdings the stock note stays absent', (tester) async {
    await _pump(tester, const Size(1200, 800));
    await _pick(tester, _key('transfer-source'), 'Norte');
    await _fillLine(tester, 0, 'Café', '');
    expect(find.text('Existencias en sucursal origen'), findsNothing);
    expect(find.textContaining('Sin entrada registrada'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final double width in <double>[400, 601, 1200]) {
    testWidgets('stock note has no overflow at $width and text scale 2', (
      tester,
    ) async {
      await _pump(
        tester,
        Size(width, 800),
        holdingsByProduct: _holdings,
        textScale: 2,
        unresolved: TransferDraft(
          idempotencyKey: 'stock-layout',
          sourceBranchId: 'branch-north',
          destinationBranchId: 'branch-south',
          lines: const <TransferLine>[
            TransferLine(
              productId: 'PRD-COFFEE-001',
              quantity: '1',
              quantitySpec: QuantitySpec(unit: 'kg', precision: 2),
            ),
            TransferLine(
              productId: 'DEMO-RIBBON-01',
              quantity: '2',
              quantitySpec: QuantitySpec(unit: 'piece', precision: 0),
            ),
          ],
        ),
      );
      expect(
        find.text('Existencias en sucursal origen'),
        width < 600 ? findsNothing : findsOneWidget,
      );
      if (width >= 600) {
        expect(find.text('Café: 12.34 kg'), findsOneWidget);
        expect(find.text('Cinta: 8 piece'), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets(
    'a retained duplicate draft bypasses the confirmation advisory',
    (WidgetTester tester) async {
      // Duplicate rows can only exist in a retained draft. Submission then
      // sends that frozen payload directly, so the per-line advisory in the
      // confirmation dialog is never computed for them.
      TransferDraft? submitted;
      await _pump(
        tester,
        const Size(1200, 800),
        holdingsByProduct: _holdings,
        submitTransfer: (TransferDraft draft) async {
          submitted = draft;
          throw StateError('test submission');
        },
        unresolved: TransferDraft(
          idempotencyKey: 'retained-key',
          sourceBranchId: 'branch-north',
          destinationBranchId: 'branch-south',
          lines: const <TransferLine>[
            TransferLine(
              productId: 'PRD-COFFEE-001',
              quantity: '7.00',
              quantitySpec: QuantitySpec(unit: 'kg', precision: 2),
            ),
            TransferLine(
              productId: 'PRD-COFFEE-001',
              quantity: '7.00',
              quantitySpec: QuantitySpec(unit: 'kg', precision: 2),
            ),
          ],
        ),
      );
      await tester.ensureVisible(_key('transfer-submit'));
      await tester.tap(_key('transfer-submit'));
      await tester.pumpAndSettle();
      expect(submitted?.lines.length, 2);
      expect(_key('transfer-confirm-dialog'), findsNothing);
      expect(
        find.textContaining('Revisa las existencias en origen de:'),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'wide: duplicate product rows sum without merging other products of the same unit',
    (WidgetTester tester) async {
      // Retained rows exercise summary aggregation without changing the editing
      // and submission rules that normally prevent duplicate products.
      await _pump(
        tester,
        const Size(1200, 800),
        unresolved: TransferDraft(
          idempotencyKey: 'retained-key',
          sourceBranchId: 'branch-north',
          destinationBranchId: 'branch-south',
          lines: const <TransferLine>[
            TransferLine(
              productId: 'PRD-COFFEE-001',
              quantity: '1.20',
              quantitySpec: QuantitySpec(unit: 'kg', precision: 2),
            ),
            TransferLine(
              productId: 'PRD-COFFEE-001',
              quantity: '1.30',
              quantitySpec: QuantitySpec(unit: 'kg', precision: 2),
            ),
            TransferLine(
              productId: 'DEMO-RIBBON-01',
              quantity: '3',
              quantitySpec: QuantitySpec(unit: 'piece', precision: 0),
            ),
            TransferLine(
              productId: 'unknown-product',
              quantity: '0.125',
              quantitySpec: QuantitySpec(unit: 'kg', precision: 3),
            ),
          ],
        ),
      );
      final Finder rail = _key('transfer-context');
      expect(
        find.descendant(of: rail, matching: find.text('Productos: 4')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: rail, matching: find.text('Café: 2.50 kg')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: rail, matching: find.text('Cinta: 3 piece')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: rail,
          matching: find.text('unknown-product: 0.125 kg'),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('wide: retained empty draft invents no product totals', (
    WidgetTester tester,
  ) async {
    await _pump(
      tester,
      const Size(1200, 800),
      unresolved: TransferDraft(
        idempotencyKey: 'empty-key',
        sourceBranchId: 'branch-north',
        destinationBranchId: 'branch-south',
        lines: const <TransferLine>[],
      ),
    );
    final List<String?> lines = tester
        .widgetList<Text>(
          find.descendant(
            of: _key('transfer-context'),
            matching: find.byType(Text),
          ),
        )
        .map((Text text) => text.data)
        .toList();
    expect(lines, <String>[
      'Resumen del traslado',
      'Origen: Norte',
      'Destino: Sur',
      'Productos: 0',
    ]);
  });

  for (final double width in <double>[400, 601, 1200]) {
    for (final bool reducedMotion in <bool>[false, true]) {
      testWidgets(
        'confirmation names, blur and no overflow at $width (reduced motion: $reducedMotion)',
        (WidgetTester tester) async {
          await _pump(
            tester,
            Size(width, 800),
            disableAnimations: reducedMotion,
          );
          await _pick(tester, _key('transfer-source'), 'Norte');
          await _pick(tester, _key('transfer-destination'), 'Sur');
          await _fillLine(tester, 0, 'Café', '2.50');
          await tester.ensureVisible(_key('transfer-add-line'));
          await tester.tap(_key('transfer-add-line'));
          await tester.pumpAndSettle();
          await _fillLine(tester, 1, 'Cinta', '3');
          expect(tester.takeException(), isNull);
          await tester.ensureVisible(_key('transfer-submit'));
          await tester.tap(_key('transfer-submit'));
          await tester.pumpAndSettle();
          expect(find.byType(BackdropFilter), findsOneWidget);
          expect(
            tester.widget<Text>(_key('transfer-confirm-line-0')).data,
            'Café: 2.50 kg',
          );
          expect(
            tester.widget<Text>(_key('transfer-confirm-line-1')).data,
            'Cinta: 3 piece',
          );
          expect(find.textContaining('PRD-COFFEE-001:'), findsNothing);
          expect(find.textContaining('DEMO-RIBBON-01:'), findsNothing);
          final ModalRoute<dynamic> route = ModalRoute.of(
            tester.element(_key('transfer-confirm-dialog')),
          )!;
          expect(route.barrierDismissible, isFalse);
          expect(
            find.descendant(
              of: find.byWidget(route.subtreeContext!.widget),
              matching: find.byType(BackdropFilter),
            ),
            findsOneWidget,
          );
          await tester.tapAt(const Offset(2, 2));
          await tester.pumpAndSettle();
          expect(_key('transfer-confirm-dialog'), findsOneWidget);
          expect(tester.takeException(), isNull);
          await tester.tap(_key('transfer-confirm-cancel'));
          await tester.pumpAndSettle();
          expect(_key('transfer-confirm-dialog'), findsNothing);
        },
      );
    }
  }

  testWidgets('narrow: no context column and the form keeps its geometry', (
    WidgetTester tester,
  ) async {
    await _pump(tester, const Size(400, 800));

    expect(_key('transfer-context'), findsNothing);
    expect(tester.getSize(_key('transfer-content')).width, 360);
    expect(tester.getTopLeft(_key('transfer-content')).dx, 20);
  });

  testWidgets('wide: context sits right of the form, form within its max', (
    WidgetTester tester,
  ) async {
    await _pump(tester, const Size(1200, 800));

    expect(_key('transfer-context'), findsOneWidget);
    final Rect content = tester.getRect(_key('transfer-content'));
    final Rect context = tester.getRect(_key('transfer-context'));
    expect(content.width, lessThanOrEqualTo(560));
    expect(context.left, greaterThanOrEqualTo(content.right));
    expect(_key('transfer-header'), findsOneWidget);
  });

  testWidgets(
    'wide: summary follows branches and totals each product separately',
    (WidgetTester tester) async {
      await _pump(tester, const Size(1200, 800));

      String summary() => tester
          .widgetList<Text>(
            find.descendant(
              of: _key('transfer-context'),
              matching: find.byType(Text),
            ),
          )
          .map((Text t) => t.data ?? '')
          .join('|');

      expect(summary(), contains('Origen: Sin seleccionar'));
      expect(summary(), contains('Destino: Sin seleccionar'));
      expect(summary(), contains('Productos: 1'));
      expect(summary(), isNot(contains('Líneas:')));
      expect(summary(), isNot(contains('Cantidad total:')));
      expect(summary(), isNot(contains('Café:')));

      await _pick(tester, _key('transfer-source'), 'Norte');
      await _pick(tester, _key('transfer-destination'), 'Sur');
      await _fillLine(tester, 0, 'Café', '2.50');
      expect(summary(), contains('Origen: Norte'));
      expect(summary(), contains('Destino: Sur'));
      expect(summary(), contains('Café: 2.50 kg'));

      await tester.tap(_key('transfer-add-line'));
      await tester.pumpAndSettle();
      expect(summary(), contains('Productos: 2'));
      expect(summary(), isNot(contains('Líneas:')));

      await _fillLine(tester, 1, 'Cinta', '3');
      expect(summary(), contains('Café: 2.50 kg|Cinta: 3 piece'));
    },
  );
}
