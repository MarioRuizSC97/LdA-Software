import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/auth/emulator_session.dart';
import 'package:lda_inventory/catalog/catalog_page.dart';
import 'package:lda_inventory/catalog/catalog_repository.dart';
import 'package:lda_inventory/catalog/product_creation.dart';
import 'package:lda_inventory/movements/administrator_movements.dart';
import 'package:lda_inventory/movements/inventory_movement.dart';
import 'package:lda_inventory/movements/seller_profiles.dart';
import 'package:lda_inventory/transfers/administrator_transfer_form.dart';
import 'package:lda_inventory/transfers/transfer_draft.dart';

Widget _page() => MaterialApp(
  home: AuthenticatedCatalogPage(
    session: const EmulatorSession(
      userId: 'test-user', email: 'test@demo.invalid',
      role: InventoryRole.administrator,
    ),
    catalogLoader: (_) async => CatalogSnapshot(const <CatalogItem>[]),
    onLogout: () async {},
    createProduct: (_) => Completer<ProductCreationResult>().future,
    submitTransfer: (_) => Completer<TransferResult>().future,
    unresolvedTransferDraft: () => null,
    administratorMovements: AdministratorMovements(
      load: (_) async => <MovementEntry>[],
      readProfile: (_) async => const SellerUnnamed(),
      setSellerName: (uid, name) async => SellerProfileResult(uid: uid, replayed: false),
    ),
  ),
);

Finder _panel(String name) => switch (name) {
  'Movimientos' => find.text('No hay movimientos'),
  _ => find.byKey(const ValueKey<String>('create-product-name')),
};

void main() {
  final platforms = TargetPlatformVariant(<TargetPlatform>{
    TargetPlatform.android, TargetPlatform.iOS, TargetPlatform.macOS,
  });
  testWidgets('Cerrar does not restore the suspended Movimientos panel', (tester) async {
    await tester.pumpWidget(_page());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Movimientos'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('transfer-open')));
    await tester.pumpAndSettle();
    final close = find.byKey(const ValueKey<String>('transfer-close'));
    await tester.ensureVisible(close);
    await tester.tap(close);
    await tester.pumpAndSettle();
    expect(_panel('Movimientos'), findsNothing);
    expect(find.byType(AdministratorTransferForm), findsNothing);
    expect(find.byKey(const ValueKey<String>('panel-back')), findsNothing);
  }, variant: platforms);
  // Correcciones → Traslados is unreachable: Correcciones is seller-only,
  // while Traslados needs a branch-less administrator.
  for (final String panel in <String>['Movimientos', 'Crear producto']) {
    for (final bool home in <bool>[false, true]) {
      testWidgets('$panel → Traslados → ${home ? 'Inicio' : 'Volver'}', (tester) async {
        await tester.pumpWidget(_page());
        await tester.pumpAndSettle();
        await tester.tap(find.text(panel));
        await tester.pumpAndSettle();
        expect(_panel(panel), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey<String>('transfer-open')));
        await tester.pumpAndSettle();
        expect(find.byType(AdministratorTransferForm), findsOneWidget);
        expect(_panel(panel), findsNothing);
        await tester.tap(find.byKey(ValueKey<String>(home ? 'shell-home' : 'panel-back')));
        await tester.pumpAndSettle();
        expect(find.byType(AdministratorTransferForm), findsNothing);
        expect(_panel(panel), home ? findsNothing : findsOneWidget);
        if (!home) {
          await tester.tap(find.byKey(const ValueKey<String>('panel-back')));
          await tester.pumpAndSettle();
        }
        expect(find.byKey(const ValueKey<String>('panel-back')), findsNothing);
      }, variant: platforms);
    }
  }
}
