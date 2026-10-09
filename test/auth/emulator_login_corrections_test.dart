import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/auth/emulator_login.dart';
import 'package:lda_inventory/auth/emulator_session.dart';
import 'package:lda_inventory/catalog/catalog_repository.dart';
import 'package:lda_inventory/firebase/emulator_correction_gateway.dart';

import '../corrections/correction_fixtures.dart';
import '../sales/sale_fixtures.dart';
import '../sales/sale_ui_fixtures.dart';

class _SessionGateway implements EmulatorSessionGateway {
  _SessionGateway({this.restored});

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

const EmulatorSession _seller = EmulatorSession(
  userId: 'demo-local-seller-north',
  email: 'seller.north@demo-lda-inventory.invalid',
  role: InventoryRole.seller,
  branchId: saleBranchId,
);
const EmulatorSession _otherSeller = EmulatorSession(
  userId: 'demo-local-seller-north-2',
  email: 'seller.north.2@demo-lda-inventory.invalid',
  role: InventoryRole.seller,
  branchId: saleBranchId,
);
const EmulatorSession _administrator = EmulatorSession(
  userId: 'demo-local-administrator',
  email: 'administrator@demo-lda-inventory.invalid',
  role: InventoryRole.administrator,
);

Future<CatalogSnapshot> _catalog(EmulatorSession session) async =>
    session.role == InventoryRole.seller
    ? sellerSaleSnapshot(branchId: session.branchId!)
    : CatalogSnapshot(const <CatalogItem>[]);

/// Real correction gateway over fake callables, recording loads and calls.
class _CorrectionBackend {
  final List<EmulatorSession> loads = <EmulatorSession>[];
  final List<Object> loadFailures = <Object>[];
  final List<Map<String, Object?>> finds = <Map<String, Object?>>[];
  int lists = 0;

  Future<EmulatorCorrectionGateway> load(EmulatorSession session) async {
    loads.add(session);
    if (loadFailures.isNotEmpty) throw loadFailures.removeAt(0);
    return EmulatorCorrectionGateway(
      expectedSession: session,
      sessionChecker: () async => session,
      findInvoke: (Map<String, Object?> request) async {
        finds.add(request);
        return findResponse();
      },
      listInvoke: (_) async {
        lists += 1;
        return <String, Object?>{
          'sales': <Object?>[lookupSaleJson()],
        };
      },
      returnInvoke: (_) async => throw UnimplementedError(),
      replacementInvoke: (_) async => throw UnimplementedError(),
      exchangeInvoke: (_) async => throw UnimplementedError(),
    );
  }
}

Widget _app(
  _SessionGateway gateway, {
  CorrectionGatewayLoader? correctionLoader,
}) => MaterialApp(
  home: EmulatorLoginShell(
    sessionGateway: Future<EmulatorSessionGateway>.value(gateway),
    catalogLoader: _catalog,
    correctionGatewayLoader: correctionLoader,
  ),
);

Finder _key(String value) => find.byKey(ValueKey<String>(value));

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('only an exact seller with a correction loader gets the entry', (
    WidgetTester tester,
  ) async {
    final _CorrectionBackend backend = _CorrectionBackend();
    for (final (
          EmulatorSession session,
          CorrectionGatewayLoader? loader,
          bool entry,
        )
        in <(EmulatorSession, CorrectionGatewayLoader?, bool)>[
          (_seller, backend.load, true),
          (_seller, null, false),
          (_administrator, backend.load, false),
        ]) {
      await tester.pumpWidget(
        _app(_SessionGateway(restored: session), correctionLoader: loader),
      );
      await tester.pumpAndSettle();
      expect(
        _key('corrections-open'),
        entry ? findsOneWidget : findsNothing,
        reason: '${session.role} $loader',
      );
      expect(find.text('Correcciones'), entry ? findsOneWidget : findsNothing);
      await tester.pumpWidget(const SizedBox());
    }
    // Showing the entry never initializes the gateway.
    expect(backend.loads, isEmpty);
  });

  testWidgets('the entry opens the lookup, and one gateway serves it all', (
    WidgetTester tester,
  ) async {
    final _CorrectionBackend backend = _CorrectionBackend();
    await tester.pumpWidget(
      _app(_SessionGateway(restored: _seller), correctionLoader: backend.load),
    );
    await tester.pumpAndSettle();
    await _tap(tester, _key('corrections-open'));

    expect(backend.lists, 1);
    expect(_key('correction-sale-$saleKey'), findsOneWidget);
    await tester.enterText(_key('correction-folio'), 'NTE-3F2A-9C1B');
    await _tap(tester, _key('correction-search'));
    expect(backend.finds.single, <String, Object?>{'folio': 'NTE-3F2A-9C1B'});
    // The catalog names the product in the detail.
    expect(
      find.descendant(
        of: _key('correction-line-0'),
        matching: find.text('Ribbon'),
      ),
      findsOneWidget,
    );

    await _tap(tester, _key('correction-detail-back'));
    await _tap(tester, _key('corrections-close'));
    expect(_key('correction-folio'), findsNothing);
    await _tap(tester, _key('corrections-open'));
    expect(backend.lists, 2);
    expect(backend.loads, <EmulatorSession>[_seller]);
  });

  testWidgets('a failed gateway initialization is dropped and retried', (
    WidgetTester tester,
  ) async {
    final _CorrectionBackend backend = _CorrectionBackend()
      ..loadFailures.add(StateError('functions unavailable'));
    await tester.pumpWidget(
      _app(_SessionGateway(restored: _seller), correctionLoader: backend.load),
    );
    await tester.pumpAndSettle();
    await _tap(tester, _key('corrections-open'));
    expect(_key('correction-recent-error'), findsOneWidget);

    await _tap(tester, _key('correction-recent-retry'));
    expect(backend.loads, hasLength(2));
    expect(backend.lists, 1);
    expect(_key('correction-sale-$saleKey'), findsOneWidget);
  });

  testWidgets('another seller gets their own gateway and a closed lookup', (
    WidgetTester tester,
  ) async {
    final _CorrectionBackend backend = _CorrectionBackend();
    final _SessionGateway sessions = _SessionGateway(restored: _seller);
    await tester.pumpWidget(_app(sessions, correctionLoader: backend.load));
    await tester.pumpAndSettle();
    await _tap(tester, _key('corrections-open'));
    expect(_key('correction-folio'), findsOneWidget);

    sessions.sessions.add(_otherSeller);
    await tester.pumpAndSettle();
    // A session change closes the corrections view.
    expect(_key('correction-folio'), findsNothing);
    await _tap(tester, _key('corrections-open'));
    expect(backend.loads, <EmulatorSession>[_seller, _otherSeller]);
  });
}
