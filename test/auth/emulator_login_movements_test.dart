import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart' show FirebaseException;
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
  Object? error;

  @override
  Future<List<MovementEntry>> recentMovements({String? branchId}) {
    loads.add(branchId);
    if (error case final Object failure) {
      return Future<List<MovementEntry>>.error(failure);
    }
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
  late int loaderFailures;

  setUp(() {
    reader = _Reader();
    profiles = _Profiles();
    loaderSessions = <EmulatorSession>[];
    loaderFailures = 0;
  });

  Widget app(_SessionGateway gateway) => MaterialApp(
    home: EmulatorLoginShell(
      sessionGateway: Future<EmulatorSessionGateway>.value(gateway),
      catalogLoader: (EmulatorSession session) async =>
          CatalogSnapshot(const <CatalogItem>[]),
      administratorMovementsLoader: (EmulatorSession session) async {
        loaderSessions.add(session);
        if (loaderFailures > 0) {
          loaderFailures -= 1;
          throw StateError('backend failed to load');
        }
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

  Future<AdministratorMovements> openMovements(
    WidgetTester tester,
    _SessionGateway gateway,
  ) async {
    await tester.pumpWidget(app(gateway));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Movimientos'));
    await tester.pumpAndSettle();
    return tester.widget<MovementsView>(find.byType(MovementsView)).movements;
  }

  testWidgets('a reader failure keeps its cause and shows its message', (
    WidgetTester tester,
  ) async {
    final FirebaseException denied = FirebaseException(
      plugin: 'cloud_firestore',
      code: 'permission-denied',
    );
    reader.error = MovementsUnavailable(cause: denied);
    await openMovements(tester, _SessionGateway(movementsAdministrator));
    expect(find.text('No tienes permiso para ver los movimientos.'), findsOne);
  });

  testWidgets('a failed backend load is retried', (WidgetTester tester) async {
    loaderFailures = 1;
    await openMovements(tester, _SessionGateway(movementsAdministrator));
    expect(find.text('No se pudieron cargar los movimientos'), findsOne);
    expect(reader.loads, isEmpty);

    await tester.tap(find.text('Reintentar'));
    await tester.pumpAndSettle();
    expect(reader.loads, <String?>[null]);
    expect(find.text('Asignar nombre'), findsOne);
    expect(loaderSessions, hasLength(2));
  });

  testWidgets('a failed loader error is kept as the cause', (
    WidgetTester tester,
  ) async {
    loaderFailures = 2;
    final AdministratorMovements movements = await openMovements(
      tester,
      _SessionGateway(movementsAdministrator),
    );
    final Object? error = await movements
        .load(null)
        .then<Object?>((_) => null, onError: (Object error) => error);
    expect(error, isA<MovementsUnavailable>());
    expect((error! as MovementsUnavailable).cause, isA<StateError>());
  });

  testWidgets('a different administrator gets a fresh backend', (
    WidgetTester tester,
  ) async {
    final _SessionGateway gateway = _SessionGateway(movementsAdministrator);
    await openMovements(tester, gateway);
    expect(loaderSessions, <EmulatorSession>[movementsAdministrator]);

    const EmulatorSession other = EmulatorSession(
      userId: 'administrator-2',
      email: 'other@demo.invalid',
      role: InventoryRole.administrator,
    );
    gateway.sessions.add(other);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Movimientos'));
    await tester.pumpAndSettle();
    expect(loaderSessions, <EmulatorSession>[movementsAdministrator, other]);
  });
}
