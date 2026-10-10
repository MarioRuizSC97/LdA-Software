import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/auth/emulator_login.dart';
import 'package:lda_inventory/auth/emulator_session.dart';
import 'package:lda_inventory/catalog/catalog_repository.dart';
import 'package:lda_inventory/catalog/firestore_catalog_repository.dart';
import 'package:lda_inventory/movements/administrator_movements.dart';
import 'package:lda_inventory/movements/inventory_movement.dart';
import 'package:lda_inventory/movements/movements_view.dart';
import 'package:lda_inventory/movements/seller_profiles.dart';

import '../movements/movement_fixtures.dart';

class _SessionGateway implements EmulatorSessionGateway {
  _SessionGateway(this.restored);

  final EmulatorSession? restored;
  final StreamController<EmulatorSession?> sessions =
      StreamController<EmulatorSession?>.broadcast();

  @override
  Future<EmulatorSession?> restoreSession() async => restored;

  @override
  Stream<EmulatorSession?> sessionChanges() => sessions.stream;

  @override
  Future<EmulatorSession> login({
    required String email,
    required String password,
  }) => throw UnimplementedError();

  @override
  Future<void> logout() async {}
}

class _Reader implements MovementReader {
  final List<String?> loads = <String?>[];
  Completer<List<MovementEntry>>? pending;

  @override
  Future<List<MovementEntry>> recentMovements({String? branchId}) {
    loads.add(branchId);
    return pending?.future ??
        Future<List<MovementEntry>>.value(<MovementEntry>[
          parseMovementEntry(
            CatalogDocument(
              path: 'inventoryMovements/m-1',
              data: movementData(actorId: unnamedSellerId),
            ),
          ),
        ]);
  }

  @override
  Future<SellerProfileLookup> sellerProfile(String uid) async =>
      const SellerUnnamed();
}

class _Profiles implements SellerProfileGateway {
  final List<String> names = <String>[];

  @override
  Future<SellerProfileResult> setSellerProfile({
    required String uid,
    required String displayName,
  }) async {
    names.add(displayName);
    return SellerProfileResult(uid: uid, replayed: false);
  }
}

void main() {
  late _Reader reader;
  late _Profiles profiles;
  late List<EmulatorSession> loaderSessions;

  setUp(() {
    reader = _Reader();
    profiles = _Profiles();
    loaderSessions = <EmulatorSession>[];
  });

  Widget app(_SessionGateway gateway) => MaterialApp(
    home: EmulatorLoginShell(
      sessionGateway: Future<EmulatorSessionGateway>.value(gateway),
      catalogLoader: (EmulatorSession session) async =>
          CatalogSnapshot(const <CatalogItem>[]),
      administratorMovementsLoader: (EmulatorSession session) async {
        loaderSessions.add(session);
        return AdministratorMovementsBackend(
          reader: reader,
          profiles: profiles,
        );
      },
    ),
  );

  testWidgets('sellers never see movements and never load the backend', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(app(_SessionGateway(movementsSeller)));
    await tester.pumpAndSettle();
    expect(find.text('Movimientos'), findsNothing);
    expect(loaderSessions, isEmpty);
  });

  testWidgets('administrators read movements and assign names', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(app(_SessionGateway(movementsAdministrator)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Movimientos'));
    await tester.pumpAndSettle();
    expect(reader.loads, <String?>[null]);
    expect(loaderSessions.single, same(movementsAdministrator));

    await tester.tap(find.text('Asignar nombre'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Bea');
    await tester.tap(find.text('Guardar'));
    await tester.pumpAndSettle();
    expect(profiles.names, <String>['Bea']);
    expect(find.text('Bea'), findsOne);
    // One backend per exact administrator.
    expect(loaderSessions, hasLength(1));
  });

  testWidgets('a session replaced during a call fails the call', (
    WidgetTester tester,
  ) async {
    final _SessionGateway gateway = _SessionGateway(movementsAdministrator);
    await tester.pumpWidget(app(gateway));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Movimientos'));
    await tester.pumpAndSettle();
    final AdministratorMovements movements = tester
        .widget<MovementsView>(find.byType(MovementsView))
        .movements;

    reader.pending = Completer<List<MovementEntry>>();
    final Future<List<MovementEntry>> load = movements.load(null);
    gateway.sessions.add(
      const EmulatorSession(
        userId: 'administrator-2',
        email: 'other@demo.invalid',
        role: InventoryRole.administrator,
      ),
    );
    await tester.pumpAndSettle();
    reader.pending!.complete(<MovementEntry>[]);
    await expectLater(load, throwsA(isA<MovementsUnavailable>()));
    await expectLater(
      movements.setSellerName('u-1', 'Bea'),
      throwsA(isA<SellerProfileSessionException>()),
    );
    expect(profiles.names, isEmpty);
  });
}
