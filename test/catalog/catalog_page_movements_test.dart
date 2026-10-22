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
  for (final double width in <double>[400, 1400]) {
    for (final bool withMovements in <bool>[true, false]) {
      for (final EmulatorSession session in <EmulatorSession>[
        movementsSeller,
        movementsAdministrator,
      ]) {
        testWidgets(
          'side panel movements: ${session.role}, controller=$withMovements, '
          'width=$width',
          (WidgetTester tester) async {
            tester.view.physicalSize = Size(width, 900);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.reset);
            await tester.pumpWidget(
              _page(session, withMovements: withMovements),
            );
            await tester.pumpAndSettle();
            await tester.tap(find.byKey(const ValueKey<String>('shell-more')));
            await tester.pumpAndSettle();
            final Finder entry = find.descendant(
              of: find.byKey(const ValueKey<String>('app-side-panel')),
              matching: find.text('Movimientos'),
            );
            // This is administrator-only even when a seller receives the
            // operations object; the panel must not expand role permissions.
            final bool allowed =
                session.role == InventoryRole.administrator && withMovements;
            expect(entry, allowed ? findsOneWidget : findsNothing);
            if (allowed) {
              await tester.tap(entry);
              await tester.pumpAndSettle();
              expect(find.text('No hay movimientos'), findsOneWidget);
            }
          },
        );
      }
    }
  }

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
