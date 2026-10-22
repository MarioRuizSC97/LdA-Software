import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/catalog/catalog_product.dart';
import 'package:lda_inventory/catalog/catalog_stock.dart';
import 'package:lda_inventory/transfers/administrator_transfer_form.dart';

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

Future<void> _pump(WidgetTester tester, Size size) async {
  useViewport(tester, size);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: AdministratorTransferForm(
          ownerUserId: 'admin-1',
          branches: _branches,
          products: _products,
          submitTransfer: (_) => throw UnimplementedError(),
          unresolvedDraft: () => null,
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

  testWidgets('wide: summary follows origin, destination, lines and total', (
    WidgetTester tester,
  ) async {
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
    expect(summary(), contains('Líneas: 1'));
    expect(summary(), contains('Cantidad total: 0'));

    await _pick(tester, _key('transfer-source'), 'Norte');
    await _pick(tester, _key('transfer-destination'), 'Sur');
    await _fillLine(tester, 0, 'Café', '2.50');
    expect(summary(), contains('Origen: Norte'));
    expect(summary(), contains('Destino: Sur'));
    expect(summary(), contains('Cantidad total: 2.50 kg'));

    await tester.tap(_key('transfer-add-line'));
    await tester.pumpAndSettle();
    expect(summary(), contains('Líneas: 2'));

    await _fillLine(tester, 1, 'Cinta', '3');
    expect(summary(), contains('Cantidad total: 2.50 kg · 3 piece'));
  });
}
