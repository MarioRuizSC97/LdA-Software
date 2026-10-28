import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/catalog/catalog_stock.dart';
import 'package:lda_inventory/catalog/firestore_catalog_repository.dart';
import 'package:lda_inventory/movements/administrator_movements.dart';
import 'package:lda_inventory/movements/inventory_movement.dart';
import 'package:lda_inventory/movements/movements_view.dart';
import 'package:lda_inventory/movements/seller_profiles.dart';

import '../support/viewport.dart';
import 'movement_fixtures.dart';

MovementEntry _entry(String id, Map<String, Object?> data) =>
    parseMovementEntry(
      CatalogDocument(path: 'inventoryMovements/$id', data: data),
    );

Finder _key(String value) => find.byKey(ValueKey<String>(value));

Future<void> _pump(WidgetTester tester, Size size) async {
  useViewport(tester, size);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: MovementsView(
          movements: AdministratorMovements(
            load: (String? branchId) async => <MovementEntry>[
              _entry('m-1', movementData()),
              _entry('m-2', movementData()),
              _entry(
                'm-3',
                movementData(
                  type: 'stock-intake',
                  quantityScaled: 1000,
                  actorId: 'administrator-1',
                  extra: const <String, Object?>{'entryId': 'e-1'},
                ),
              ),
              _entry('m-4', movementData(type: 'teleport')),
            ],
            readProfile: (String uid) async => const SellerUnnamed(),
            setSellerName: (String uid, String name) async =>
                SellerProfileResult(uid: uid, replayed: false),
          ),
          productNames: const <String, String>{'PRD-COFFEE-001': 'Café'},
          branchChoices: const <CatalogBranchChoice>[
            CatalogBranchChoice(branchId: 'branch-north', branchName: 'Norte'),
          ],
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('narrow: no context and rows keep their geometry', (
    WidgetTester tester,
  ) async {
    await _pump(tester, const Size(400, 800));

    expect(_key('movements-context'), findsNothing);
    final Rect row = tester.getRect(_key('movement-m-1'));
    expect(row.left, 16);
    expect(row.width, 368);
  });

  testWidgets('wide: context right of the list, list within its max', (
    WidgetTester tester,
  ) async {
    await _pump(tester, const Size(1200, 800));

    expect(_key('movements-context'), findsOneWidget);
    final Rect row = tester.getRect(_key('movement-m-1'));
    expect(row.width, lessThanOrEqualTo(760));
    expect(
      tester.getRect(_key('movements-context')).left,
      greaterThanOrEqualTo(row.right),
    );
  });

  testWidgets('wide: context summarizes the filtered set by type', (
    WidgetTester tester,
  ) async {
    await _pump(tester, const Size(1200, 800));

    Finder inContext(String text) => find.descendant(
      of: _key('movements-context'),
      matching: find.text(text),
    );
    expect(inContext('Filtro: Todas'), findsOneWidget);
    expect(inContext('Movimientos: 4'), findsOneWidget);
    expect(inContext('Venta: 2'), findsOneWidget);
    expect(inContext('Entrada de stock: 1'), findsOneWidget);
    expect(inContext('Ilegibles: 1'), findsOneWidget);
  });
}
