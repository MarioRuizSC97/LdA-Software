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
}) async {
  useViewport(tester, size);
  await tester.pumpWidget(
    MaterialApp(
      builder: (BuildContext context, Widget? child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(disableAnimations: disableAnimations),
        child: child!,
      ),
      home: Scaffold(
        body: AdministratorTransferForm(
          ownerUserId: 'admin-1',
          branches: _branches,
          products: _products,
          submitTransfer: (_) => throw UnimplementedError(),
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

void main() {
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
