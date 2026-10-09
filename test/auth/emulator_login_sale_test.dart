import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/auth/emulator_login.dart';
import 'package:lda_inventory/auth/emulator_session.dart';
import 'package:lda_inventory/catalog/catalog_repository.dart';
import 'package:lda_inventory/firebase/emulator_sale_gateway.dart';

import '../sales/sale_ui_fixtures.dart';

class _SessionGateway implements EmulatorSessionGateway {
  _SessionGateway({this.restored, this.loginResult});

  final EmulatorSession? restored;
  final EmulatorSession? loginResult;
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
  }) async => loginResult!;

  @override
  Future<void> logout() async {}
}

const EmulatorSession _seller = EmulatorSession(
  userId: 'demo-local-seller-north',
  email: 'seller.north@demo-lda-inventory.invalid',
  role: InventoryRole.seller,
  branchId: 'branch-north',
);
const EmulatorSession _otherSeller = EmulatorSession(
  userId: 'demo-local-seller-north-2',
  email: 'seller.north.2@demo-lda-inventory.invalid',
  role: InventoryRole.seller,
  branchId: 'branch-north',
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

/// Real sale gateway over fake callables, recording loader and submit calls.
///
/// [current] is what the gateway's own session checker sees (null means the
/// session it was built for); [loadFailures] fail initializations in order;
/// [duringSubmit] runs inside the callable, before its outcome.
class _SaleBackend {
  int loads = 0;
  final List<Map<String, Object?>> submits = <Map<String, Object?>>[];
  final List<Object> submitFailures = <Object>[];
  final List<Object> loadFailures = <Object>[];
  EmulatorSession? current;
  void Function()? duringSubmit;

  Future<EmulatorSaleGateway> load(EmulatorSession session) async {
    loads += 1;
    if (loadFailures.isNotEmpty) throw loadFailures.removeAt(0);
    return EmulatorSaleGateway(
      expectedSession: session,
      sessionChecker: () async => current ?? session,
      quoteInvoke: (Map<String, Object?> request) async =>
          quoteFor(cartForRequest(request)),
      submitInvoke: (Map<String, Object?> request) async {
        submits.add(request);
        duringSubmit?.call();
        if (submitFailures.isNotEmpty) throw submitFailures.removeAt(0);
        return submitResponseForRequest(request);
      },
    );
  }
}

Widget _app(_SessionGateway gateway, {SaleGatewayLoader? saleLoader}) =>
    MaterialApp(
      home: EmulatorLoginShell(
        sessionGateway: Future<EmulatorSessionGateway>.value(gateway),
        catalogLoader: _catalog,
        saleGatewayLoader: saleLoader,
      ),
    );

Finder _key(String value) => find.byKey(ValueKey<String>(value));

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> _addRibbonAndCharge(WidgetTester tester) async {
  await _tap(tester, _key('sale-add-DEMO-RIBBON'));
  await tester.enterText(_key('sale-quantity-DEMO-RIBBON'), '2');
  await _tap(tester, _key('sale-entry-save-DEMO-RIBBON'));
  await _tap(tester, _key('sale-cart-button'));
  await _tap(tester, _key('sale-charge'));
}

void main() {
  testWidgets('only an exact seller with a sale loader gets the cart', (
    WidgetTester tester,
  ) async {
    final _SaleBackend backend = _SaleBackend();
    for (final (EmulatorSession session, SaleGatewayLoader? loader, bool cart)
        in <(EmulatorSession, SaleGatewayLoader?, bool)>[
          (_seller, backend.load, true),
          (_seller, null, false),
          (_administrator, backend.load, false),
        ]) {
      await tester.pumpWidget(
        _app(_SessionGateway(restored: session), saleLoader: loader),
      );
      await tester.pumpAndSettle();
      expect(
        _key('sale-cart-button'),
        cart ? findsOneWidget : findsNothing,
        reason: '${session.role} $loader',
      );
      expect(
        _key('sale-add-DEMO-RIBBON'),
        cart ? findsOneWidget : findsNothing,
      );
      expect(find.text('Agregar'), cart ? findsWidgets : findsNothing);
      await tester.pumpWidget(const SizedBox());
    }
    expect(backend.loads, 0);
  });

  testWidgets('a seller completes a sale through one bound gateway', (
    WidgetTester tester,
  ) async {
    final _SaleBackend backend = _SaleBackend();
    await tester.pumpWidget(
      _app(_SessionGateway(restored: _seller), saleLoader: backend.load),
    );
    await tester.pumpAndSettle();

    await _addRibbonAndCharge(tester);

    expect(backend.loads, 1);
    final Map<String, Object?> request = backend.submits.single;
    expect(request['payment'], <String, Object?>{
      'method': 'cash',
      'amountCentavos': 2000,
    });
    final String key = request['idempotencyKey']! as String;
    expect(
      tester.widget<Text>(_key('sale-receipt-folio')).data,
      startsWith('NTE-${key.substring(0, 4).toUpperCase()}'),
    );
    await _tap(tester, _key('sale-receipt-new'));
    expect(find.textContaining('Carrito vacío'), findsOneWidget);
  });

  testWidgets('a failed gateway initialization is dropped and retried', (
    WidgetTester tester,
  ) async {
    final _SaleBackend backend = _SaleBackend()
      ..loadFailures.add(StateError('functions unavailable'));
    await tester.pumpWidget(
      _app(_SessionGateway(restored: _seller), saleLoader: backend.load),
    );
    await tester.pumpAndSettle();
    await _tap(tester, _key('sale-add-DEMO-RIBBON'));
    await tester.enterText(_key('sale-quantity-DEMO-RIBBON'), '2');
    await _tap(tester, _key('sale-entry-save-DEMO-RIBBON'));
    await _tap(tester, _key('sale-cart-button'));

    expect(backend.loads, 1);
    expect(find.text('No se pudo calcular el total'), findsOneWidget);

    await _tap(tester, _key('sale-retry-quote'));
    expect(backend.loads, 2);
    expect(find.textContaining('20.00 MXN'), findsWidgets);

    await _tap(tester, _key('sale-charge'));
    expect(backend.loads, 2);
    expect(backend.submits, hasLength(1));
    expect(_key('sale-receipt-folio'), findsOneWidget);
  });

  testWidgets('a seller change seen before the call locks the stored draft '
      'without sending it', (WidgetTester tester) async {
    final _SaleBackend backend = _SaleBackend();
    await tester.pumpWidget(
      _app(_SessionGateway(restored: _seller), saleLoader: backend.load),
    );
    await tester.pumpAndSettle();
    await _tap(tester, _key('sale-add-DEMO-RIBBON'));
    await tester.enterText(_key('sale-quantity-DEMO-RIBBON'), '2');
    await _tap(tester, _key('sale-entry-save-DEMO-RIBBON'));
    await _tap(tester, _key('sale-cart-button'));
    backend.current = _otherSeller;
    await _tap(tester, _key('sale-charge'));

    // The quote ran before the switch; the submit's pre-call check refused.
    expect(backend.submits, isEmpty);
    expect(_key('sale-retry-submit'), findsOneWidget);
    expect(_key('sale-receipt-folio'), findsNothing);

    backend.current = null;
    await _tap(tester, _key('sale-retry-submit'));
    expect(backend.submits, hasLength(1));
    expect(_key('sale-receipt-folio'), findsOneWidget);
  });

  for (final bool rejected in <bool>[false, true]) {
    testWidgets('a seller change during the call makes a '
        '${rejected ? 'rejection' : 'success'} uncertain', (
      WidgetTester tester,
    ) async {
      final _SaleBackend backend = _SaleBackend();
      if (rejected) {
        backend.submitFailures.add(
          const SaleCallableException(
            code: 'invalid-argument',
            message: 'full payment must equal the authoritative total',
            reason: 'payment-mismatch',
          ),
        );
      }
      final _SessionGateway gateway = _SessionGateway(restored: _seller);
      // The gateway's own checks still pass; only the shell sees the switch.
      backend.duringSubmit = () {
        backend.duringSubmit = null;
        gateway.sessions.add(_otherSeller);
      };
      await tester.pumpWidget(_app(gateway, saleLoader: backend.load));
      await tester.pumpAndSettle();
      await _addRibbonAndCharge(tester);

      expect(backend.submits, hasLength(1));
      expect(_key('sale-receipt-folio'), findsNothing);
      expect(find.textContaining('Carrito vacío'), findsOneWidget);

      // The draft stayed stored for the original seller: same-key retry.
      gateway.sessions.add(_seller);
      await tester.pumpAndSettle();
      expect(find.textContaining('1 producto · 20.00 MXN'), findsOneWidget);
      await _tap(tester, _key('sale-cart-button'));
      expect(_key('sale-retry-submit'), findsOneWidget);
      await _tap(tester, _key('sale-retry-submit'));
      expect(backend.submits, hasLength(2));
      expect(backend.submits[1], backend.submits[0]);
      expect(_key('sale-receipt-folio'), findsOneWidget);
    });
  }

  testWidgets('an uncertain sale survives re-login and retries the same key', (
    WidgetTester tester,
  ) async {
    final _SaleBackend backend = _SaleBackend()
      ..submitFailures.add(
        const SaleCallableException(code: 'internal', message: ''),
      );
    final _SessionGateway gateway = _SessionGateway(
      restored: _seller,
      loginResult: _seller,
    );
    await tester.pumpWidget(_app(gateway, saleLoader: backend.load));
    await tester.pumpAndSettle();
    await _addRibbonAndCharge(tester);
    expect(_key('sale-retry-submit'), findsOneWidget);

    await _tap(tester, find.widgetWithText(OutlinedButton, 'Log out'));
    await tester.enterText(_key('login-email'), _seller.email);
    await tester.enterText(_key('login-password'), 'Demo-Only-Seller-2026!');
    await _tap(tester, find.widgetWithText(FilledButton, 'Sign in'));

    expect(_key('sale-cart-button'), findsOneWidget);
    expect(find.textContaining('1 producto · 20.00 MXN'), findsOneWidget);
    await _tap(tester, _key('sale-cart-button'));
    await _tap(tester, _key('sale-retry-submit'));

    expect(backend.submits, hasLength(2));
    expect(backend.submits[1], backend.submits[0]);
    expect(find.text('Venta registrada'), findsOneWidget);
  });

  testWidgets('another seller never sees an unresolved sale', (
    WidgetTester tester,
  ) async {
    final _SaleBackend backend = _SaleBackend()
      ..submitFailures.add(
        const SaleCallableException(code: 'internal', message: ''),
      );
    final _SessionGateway gateway = _SessionGateway(restored: _seller);
    await tester.pumpWidget(_app(gateway, saleLoader: backend.load));
    await tester.pumpAndSettle();
    await _addRibbonAndCharge(tester);
    expect(_key('sale-retry-submit'), findsOneWidget);

    gateway.sessions.add(_otherSeller);
    await tester.pumpAndSettle();

    expect(find.textContaining('Carrito vacío'), findsOneWidget);
    expect(_key('sale-retry-submit'), findsNothing);
  });
}
