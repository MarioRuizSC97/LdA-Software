import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/app/inventory_theme.dart';
import 'package:lda_inventory/catalog/catalog_stock.dart';
import 'package:lda_inventory/catalog/firestore_catalog_repository.dart';
import 'package:lda_inventory/movements/administrator_movements.dart';
import 'package:lda_inventory/movements/inventory_movement.dart';
import 'package:lda_inventory/movements/movements_view.dart';
import 'package:lda_inventory/movements/seller_profiles.dart';

import '../movements/movement_fixtures.dart';
import '../support/viewport.dart';

Finder _key(String key) => find.byKey(ValueKey(key));
MovementEntry _entry({String product = 'PRD-COFFEE-001', String branch = 'branch-north'}) => parseMovementEntry(CatalogDocument(path: 'inventoryMovements/audit-row', data: movementData(productId: product, branchId: branch)));

Widget _app(AdministratorMovements movements, Brightness brightness) => MaterialApp(
  theme: brightness == Brightness.light ? buildInventoryTheme() : buildDarkInventoryTheme(),
  home: Scaffold(body: MovementsView(movements: movements, productNames: const {'PRD-COFFEE-001': 'Café'}, branchChoices: const [CatalogBranchChoice(branchId: 'branch-north', branchName: 'Norte'), CatalogBranchChoice(branchId: 'branch-south', branchName: 'Sur')], onClose: () {})),
);
AdministratorMovements _backend(Future<List<MovementEntry>> Function(String?) load, {Future<SellerProfileResult> Function(String, String)? save}) => AdministratorMovements(load: load, readProfile: (_) async => const SellerNamed('Ana López'), setSellerName: save ?? (uid, _) async => SellerProfileResult(uid: uid, replayed: false));

void main() {
  for (final width in [320.0, 400.0, 600.0, 1200.0]) {
    for (final brightness in Brightness.values) {
      testWidgets('ledger menu and name editor fit $width ${brightness.name} scale 1.3', (tester) async {
        useViewport(tester, Size(width, 900), 1.3);
        final loads = <String?>[];
        await tester.pumpWidget(_app(_backend((branch) async { loads.add(branch); return [_entry()]; }), brightness));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.tap(_key('movements-branch-filter'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('Sur').last);
        await tester.pumpAndSettle();
        expect(loads, [null, 'branch-south']);
        await tester.tap(find.text('Editar nombre'));
        await tester.pumpAndSettle();
        await tester.enterText(_key('seller-name-field'), 'María de los Ángeles Hernández');
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('Cancelar'));
        await tester.pumpAndSettle();
        expect(find.text('Ana López'), findsWidgets);
        expect(tester.takeException(), isNull);
      });
      testWidgets('ledger pending error empty stay honest $width ${brightness.name}', (tester) async {
        useViewport(tester, Size(width, 900), 1.3);
        final pending = Completer<List<MovementEntry>>();
        var retry = false;
        await tester.pumpWidget(_app(_backend((_) => retry ? Future.value([]) : pending.future), brightness));
        await tester.pump();
        expect(_key('movements-loading'), findsOneWidget);
        expect(find.text('Movimientos: 0'), findsNothing, reason: 'D2: pending is not an empty result');
        expect(tester.takeException(), isNull);
        pending.completeError(StateError('PRIVATE backend stack trace'));
        await tester.pumpAndSettle();
        expect(find.textContaining('PRIVATE'), findsNothing);
        expect(find.text('Movimientos: 0'), findsNothing, reason: 'D2: a failed load is not zero movements');
        expect(tester.takeException(), isNull);
        retry = true;
        await tester.tap(find.text('Reintentar'));
        await tester.pumpAndSettle();
        expect(find.text('No hay movimientos'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  }
  testWidgets('name save double tap invokes gateway once', (tester) async {
    final reply = Completer<SellerProfileResult>();
    var calls = 0;
    await tester.pumpWidget(_app(_backend((_) async => [_entry()], save: (uid, name) { calls++; return reply.future; }), Brightness.light));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Editar nombre'));
    await tester.pumpAndSettle();
    await tester.enterText(_key('seller-name-field'), 'Beatriz');
    final save = find.widgetWithText(FilledButton, 'Guardar');
    await tester.tap(save);
    await tester.tap(save);
    await tester.pump();
    expect(calls, 1);
    reply.complete(SellerProfileResult(uid: namedSellerId, replayed: false));
    await tester.pumpAndSettle();
    expect(find.text('Beatriz'), findsWidgets);
    expect(tester.takeException(), isNull);
  });
  testWidgets('missing catalog labels never expose raw product or branch ids', (tester) async {
    await tester.pumpWidget(_app(_backend((_) async => [_entry(product: 'PRD-UNKNOWN-01', branch: 'branch-private')]), Brightness.light));
    await tester.pumpAndSettle();
    expect(find.textContaining('PRD-UNKNOWN-01'), findsNothing, reason: 'T22 D2: use human-readable unavailable labels, not raw ids');
    expect(find.textContaining('branch-private'), findsNothing);
  });
}
