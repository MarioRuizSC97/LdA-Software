import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/auth/emulator_session.dart';
import 'package:lda_inventory/catalog/catalog_page.dart';
import 'package:lda_inventory/catalog/catalog_repository.dart';
import 'package:lda_inventory/movements/administrator_movements.dart';
import 'package:lda_inventory/movements/inventory_movement.dart';
import 'package:lda_inventory/movements/seller_profiles.dart';

import '../movements/movement_fixtures.dart';

final AdministratorMovements _movements = AdministratorMovements(
  load: (String? branchId) async => <MovementEntry>[],
  readProfile: (String uid) async => const SellerUnnamed(),
  setSellerName: (String uid, String name) async =>
      SellerProfileResult(uid: uid, replayed: false),
);

Widget _page(EmulatorSession session, {bool withMovements = true}) =>
    MaterialApp(
      home: AuthenticatedCatalogPage(
        session: session,
        catalogLoader: (EmulatorSession session) async =>
            CatalogSnapshot(const <CatalogItem>[]),
        onLogout: () async {},
        administratorMovements: withMovements ? _movements : null,
      ),
    );

const EmulatorSession _otherAdministrator = EmulatorSession(
  userId: 'administrator-2',
  email: 'other@demo.invalid',
  role: InventoryRole.administrator,
);

Future<void> _open(WidgetTester tester) async {
  await tester.pumpWidget(_page(movementsAdministrator));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Movimientos'));
  await tester.pumpAndSettle();
  expect(find.text('No hay movimientos'), findsOne);
}

void main() {
  testWidgets('sellers never get the entry, even if handed one', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_page(movementsSeller));
    await tester.pumpAndSettle();
    expect(find.text('Movimientos'), findsNothing);
  });

  testWidgets('administrators open movements in place of the catalog', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_page(movementsAdministrator));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Movimientos'));
    await tester.pumpAndSettle();
    expect(find.text('No hay movimientos'), findsOne);
    expect(find.text('Todas'), findsOne);

    await tester.tap(find.text('Volver'));
    await tester.pumpAndSettle();
    expect(find.text('No hay movimientos'), findsNothing);
    expect(find.text('Movimientos'), findsOne);
  });

  testWidgets('a session change closes the movements view', (
    WidgetTester tester,
  ) async {
    await _open(tester);
    await tester.pumpWidget(_page(_otherAdministrator));
    await tester.pumpAndSettle();
    expect(find.text('No hay movimientos'), findsNothing);
    expect(find.text('Movimientos'), findsOne);
  });

  testWidgets('removing the movements operations closes the view', (
    WidgetTester tester,
  ) async {
    await _open(tester);
    await tester.pumpWidget(
      _page(movementsAdministrator, withMovements: false),
    );
    await tester.pumpAndSettle();
    expect(find.text('No hay movimientos'), findsNothing);
    expect(find.text('Movimientos'), findsNothing);

    // Handing them back does not reopen the view.
    await tester.pumpWidget(_page(movementsAdministrator));
    await tester.pumpAndSettle();
    expect(find.text('No hay movimientos'), findsNothing);
    expect(find.text('Movimientos'), findsOne);
  });
}
