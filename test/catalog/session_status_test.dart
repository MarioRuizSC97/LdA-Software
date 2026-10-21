import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/app/backend_environment.dart';
import 'package:lda_inventory/auth/emulator_session.dart';
import 'package:lda_inventory/catalog/catalog_page.dart';
import 'package:lda_inventory/catalog/catalog_stock.dart';

const EmulatorSession _seller = EmulatorSession(
  userId: 'seller-north',
  email: 'seller@demo.invalid',
  role: InventoryRole.seller,
  branchId: 'branch-north',
);

const EmulatorSession _administrator = EmulatorSession(
  userId: 'administrator',
  email: 'admin@demo.invalid',
  role: InventoryRole.administrator,
);

Widget _page(EmulatorSession session, BackendEnvironment environment) =>
    MaterialApp(
      home: AuthenticatedCatalogPage(
        session: session,
        environment: environment,
        catalogLoader: (_) => Completer<CatalogSnapshot>().future,
        onLogout: () async {},
      ),
    );

String _statusText(WidgetTester tester) => tester
    .widget<Text>(find.byKey(const ValueKey<String>('session-status')))
    .data!;

void main() {
  group('session status in the app bar', () {
    testWidgets('production seller sees role and branch, never the email', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(_page(_seller, BackendEnvironment.production));

      expect(_statusText(tester), 'Vendedor · Sucursal North');
      expect(
        find.descendant(
          of: find.byType(AppBar),
          matching: find.byKey(const ValueKey<String>('session-status')),
        ),
        findsOneWidget,
      );
      expect(find.textContaining('seller@demo.invalid'), findsNothing);
      expect(find.text('Sesión iniciada'), findsNothing);
      expect(find.text('Rol: Vendedor'), findsNothing);
      expect(find.text('Sucursal: branch-north'), findsNothing);
    });

    testWidgets('production administrator sees only the role', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        _page(_administrator, BackendEnvironment.production),
      );

      expect(_statusText(tester), 'Administrador');
      expect(find.textContaining('admin@demo.invalid'), findsNothing);
    });

    testWidgets('local emulator sessions stay marked as local', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        _page(_administrator, BackendEnvironment.localEmulator),
      );

      expect(_statusText(tester), 'Emulador local · Administrador');
      expect(find.text('Autenticado localmente'), findsNothing);
    });

    testWidgets('multi-word branch ids read as title case', (
      WidgetTester tester,
    ) async {
      const EmulatorSession seller = EmulatorSession(
        userId: 'seller-centro-sur',
        email: 'seller@demo.invalid',
        role: InventoryRole.seller,
        branchId: 'branch-centro-sur',
      );
      await tester.pumpWidget(_page(seller, BackendEnvironment.production));

      expect(_statusText(tester), 'Vendedor · Sucursal Centro Sur');
    });
  });
}
