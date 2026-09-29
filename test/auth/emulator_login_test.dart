import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/auth/emulator_login.dart';
import 'package:lda_inventory/auth/emulator_session.dart';
import 'package:lda_inventory/catalog/catalog_page.dart';
import 'package:lda_inventory/catalog/catalog_product.dart';
import 'package:lda_inventory/catalog/catalog_repository.dart';

class _FakeGateway implements EmulatorSessionGateway {
  _FakeGateway({
    this.restored,
    this.restoreError,
    this.loginResult,
    this.loginError,
    this.loginCompleter,
    this.logoutCompleter,
  });

  final EmulatorSession? restored;
  Object? restoreError;
  final EmulatorSession? loginResult;
  final Object? loginError;
  Completer<EmulatorSession>? loginCompleter;
  final Completer<void>? logoutCompleter;
  final StreamController<EmulatorSession?> sessions =
      StreamController<EmulatorSession?>.broadcast();
  var restoreCalls = 0;
  var logoutCalls = 0;
  String? submittedEmail;
  String? submittedPassword;

  @override
  Future<EmulatorSession?> restoreSession() async {
    restoreCalls += 1;
    if (restoreError case final Object error) throw error;
    return restored;
  }

  @override
  Stream<EmulatorSession?> sessionChanges() => sessions.stream;

  @override
  Future<EmulatorSession> login({
    required String email,
    required String password,
  }) async {
    submittedEmail = email;
    submittedPassword = password;
    if (loginError case final Object error) throw error;
    if (loginCompleter case final Completer<EmulatorSession> completer) {
      return completer.future;
    }
    return loginResult!;
  }

  @override
  Future<void> logout() async {
    logoutCalls += 1;
    await logoutCompleter?.future;
  }
}

const EmulatorSession _seller = EmulatorSession(
  userId: 'demo-local-seller-north',
  email: 'seller.north@demo-lda-inventory.invalid',
  role: InventoryRole.seller,
  branchId: 'branch-north',
);

Future<CatalogSnapshot> _emptyCatalog(EmulatorSession session) async =>
    CatalogSnapshot(const <CatalogItem>[]);

Widget _app(
  Future<EmulatorSessionGateway> gateway, {
  CatalogSnapshotLoader catalogLoader = _emptyCatalog,
}) => MaterialApp(
  home: EmulatorLoginShell(
    sessionGateway: gateway,
    catalogLoader: catalogLoader,
  ),
);

void main() {
  testWidgets('shows a safe loading state while bootstrap is pending', (
    WidgetTester tester,
  ) async {
    final Completer<EmulatorSessionGateway> completer =
        Completer<EmulatorSessionGateway>();

    await tester.pumpWidget(_app(completer.future));

    expect(find.text('Connecting to local Auth emulator'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('shows login after an unauthenticated restore', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_app(Future.value(_FakeGateway())));
    await tester.pumpAndSettle();

    expect(find.text('Local emulator sign in'), findsOneWidget);
    expect(find.byType(TextFormField), findsNWidgets(2));
    expect(find.text('Catalog data is not connected.'), findsOneWidget);
  });

  testWidgets('logs in and loads catalog for the validated session', (
    WidgetTester tester,
  ) async {
    final _FakeGateway gateway = _FakeGateway(loginResult: _seller);
    await tester.pumpWidget(_app(Future.value(gateway)));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey<String>('login-email')),
      ' seller.north@demo-lda-inventory.invalid ',
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('login-password')),
      'Demo-Only-Seller-2026!',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pumpAndSettle();

    expect(gateway.submittedEmail, 'seller.north@demo-lda-inventory.invalid');
    expect(gateway.submittedPassword, 'Demo-Only-Seller-2026!');
    expect(find.text('Authenticated locally'), findsOneWidget);
    expect(find.text('Role: seller'), findsOneWidget);
    expect(find.text('Branch: branch-north'), findsOneWidget);
    expect(find.text('No products yet'), findsOneWidget);
    expect(find.text('Coffee'), findsNothing);
  });

  testWidgets('shows a safe error and no authenticated content on failure', (
    WidgetTester tester,
  ) async {
    final _FakeGateway gateway = _FakeGateway(
      loginError: StateError('secret network details'),
    );
    await tester.pumpWidget(_app(Future.value(gateway)));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey<String>('login-email')),
      'user@example.invalid',
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('login-password')),
      'password',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pumpAndSettle();

    expect(
      find.text('Unable to sign in to the local emulator.'),
      findsOneWidget,
    );
    expect(find.textContaining('secret network details'), findsNothing);
    expect(find.text('Authenticated locally'), findsNothing);
  });

  testWidgets('logs out to the login form', (WidgetTester tester) async {
    final _FakeGateway gateway = _FakeGateway(restored: _seller);
    await tester.pumpWidget(_app(Future.value(gateway)));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(OutlinedButton, 'Log out'));
    await tester.pumpAndSettle();

    expect(gateway.logoutCalls, 1);
    expect(find.text('Local emulator sign in'), findsOneWidget);
  });

  testWidgets('remote sign-out immediately clears authenticated content', (
    WidgetTester tester,
  ) async {
    final _FakeGateway gateway = _FakeGateway(restored: _seller);
    await tester.pumpWidget(_app(Future.value(gateway)));
    await tester.pumpAndSettle();

    gateway.sessions.add(null);
    await tester.pumpAndSettle();

    expect(find.text('Authenticated locally'), findsNothing);
    expect(find.text('Local emulator sign in'), findsOneWidget);
    expect(find.text('Coffee'), findsNothing);
  });

  testWidgets('token claim changes replace role and branch presentation', (
    WidgetTester tester,
  ) async {
    final _FakeGateway gateway = _FakeGateway(restored: _seller);
    await tester.pumpWidget(_app(Future.value(gateway)));
    await tester.pumpAndSettle();

    gateway.sessions.add(
      const EmulatorSession(
        userId: 'demo-local-administrator',
        email: 'administrator@demo-lda-inventory.invalid',
        role: InventoryRole.administrator,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Role: administrator'), findsOneWidget);
    expect(find.text('Branch: branch-north'), findsNothing);

    gateway.sessions.add(
      const EmulatorSession(
        userId: 'demo-local-seller-south',
        email: 'seller.south@demo-lda-inventory.invalid',
        role: InventoryRole.seller,
        branchId: 'branch-south',
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Role: seller'), findsOneWidget);
    expect(find.text('Branch: branch-south'), findsOneWidget);
    expect(find.text('Branch: branch-north'), findsNothing);
  });

  testWidgets('remote disablement clears session and fails closed', (
    WidgetTester tester,
  ) async {
    final _FakeGateway gateway = _FakeGateway(restored: _seller);
    await tester.pumpWidget(_app(Future.value(gateway)));
    await tester.pumpAndSettle();

    gateway.sessions.addError(const UntrustedSessionException());
    await tester.pumpAndSettle();

    expect(find.text('Authenticated locally'), findsNothing);
    expect(find.text('Session rejected'), findsOneWidget);
    expect(find.text('Coffee'), findsNothing);
  });

  testWidgets('cancels the auth lifecycle subscription when disposed', (
    WidgetTester tester,
  ) async {
    final _FakeGateway gateway = _FakeGateway(restored: _seller);
    await tester.pumpWidget(_app(Future.value(gateway)));
    await tester.pumpAndSettle();
    expect(gateway.sessions.hasListener, isTrue);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    expect(gateway.sessions.hasListener, isFalse);
  });

  testWidgets('rejected restored session is not labeled as bootstrap failure', (
    WidgetTester tester,
  ) async {
    final _FakeGateway gateway = _FakeGateway(
      restoreError: const UntrustedSessionException(),
    );
    await tester.pumpWidget(_app(Future.value(gateway)));
    await tester.pumpAndSettle();

    expect(find.text('Session rejected'), findsOneWidget);
    expect(find.text('Local Auth emulator unavailable'), findsNothing);
    expect(find.text('Authenticated locally'), findsNothing);
  });

  testWidgets('connection retry reuses the initialized gateway', (
    WidgetTester tester,
  ) async {
    final _FakeGateway gateway = _FakeGateway(
      restoreError: const EmulatorSessionConnectionException(),
    );
    var loaderCalls = 0;
    Future<EmulatorSessionGateway> loader() async {
      loaderCalls += 1;
      return gateway;
    }

    await tester.pumpWidget(
      MaterialApp(
        home: EmulatorLoginShell(
          sessionGateway: loader(),
          retryLoader: loader,
          catalogLoader: _emptyCatalog,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Unable to verify session'), findsOneWidget);
    expect(loaderCalls, 1);

    gateway.restoreError = null;
    await tester.tap(find.widgetWithText(FilledButton, 'Try again'));
    await tester.pumpAndSettle();

    expect(loaderCalls, 1);
    expect(gateway.restoreCalls, 2);
    expect(find.text('Local emulator sign in'), findsOneWidget);
  });

  testWidgets('authenticated catalog auto-loads once for harmless notices', (
    WidgetTester tester,
  ) async {
    final _FakeGateway gateway = _FakeGateway(restored: _seller);
    var catalogCalls = 0;
    Future<CatalogSnapshot> load(EmulatorSession session) async {
      catalogCalls += 1;
      return CatalogSnapshot(<CatalogItem>[
        CatalogItem(
          product: const CatalogProduct(
            internalCode: 'PRD-LIVE-001',
            name: 'Live product',
            quantitySpec: QuantitySpec(unit: 'piece', precision: 0),
          ),
          holdings: const <CatalogHolding>[
            CatalogHolding(branchId: 'branch-north', quantityScaled: 1),
          ],
        ),
      ]);
    }

    await tester.pumpWidget(
      _app(Future<EmulatorSessionGateway>.value(gateway), catalogLoader: load),
    );
    await tester.pumpAndSettle();
    expect(find.text('Live product'), findsOneWidget);
    expect(catalogCalls, 1);

    gateway.sessions.add(_seller);
    await tester.pumpAndSettle();
    expect(catalogCalls, 1);
  });

  testWidgets('user role and branch changes recreate and clear catalog', (
    WidgetTester tester,
  ) async {
    final _FakeGateway gateway = _FakeGateway(restored: _seller);
    final List<EmulatorSession> requested = <EmulatorSession>[];
    final List<Completer<CatalogSnapshot>> requests =
        <Completer<CatalogSnapshot>>[];
    Future<CatalogSnapshot> load(EmulatorSession session) {
      requested.add(session);
      final Completer<CatalogSnapshot> completer =
          Completer<CatalogSnapshot>();
      requests.add(completer);
      return completer.future;
    }

    await tester.pumpWidget(
      _app(Future<EmulatorSessionGateway>.value(gateway), catalogLoader: load),
    );
    await tester.pump();
    expect(requested, hasLength(1));

    const List<EmulatorSession> replacements = <EmulatorSession>[
      EmulatorSession(
        userId: 'seller-north',
        email: 'seller@demo.invalid',
        role: InventoryRole.seller,
        branchId: 'branch-south',
      ),
      EmulatorSession(
        userId: 'seller-north',
        email: 'seller@demo.invalid',
        role: InventoryRole.administrator,
      ),
      EmulatorSession(
        userId: 'another-admin',
        email: 'other@demo.invalid',
        role: InventoryRole.administrator,
      ),
    ];
    for (final EmulatorSession replacement in replacements) {
      gateway.sessions.add(replacement);
      await tester.pump();
      expect(find.bySemanticsLabel('Loading catalog'), findsOneWidget);
    }
    expect(requested, hasLength(4));
    expect(requested.last.userId, 'another-admin');
  });

  testWidgets('delayed logout rejects stale nonnull session events', (
    WidgetTester tester,
  ) async {
    final Completer<void> signOut = Completer<void>();
    final _FakeGateway gateway = _FakeGateway(
      restored: _seller,
      logoutCompleter: signOut,
    );
    var catalogCalls = 0;
    Future<CatalogSnapshot> load(EmulatorSession session) async {
      catalogCalls += 1;
      return CatalogSnapshot(<CatalogItem>[
        CatalogItem(
          product: const CatalogProduct(
            internalCode: 'PRD-LIVE-001',
            name: 'Live product',
            quantitySpec: QuantitySpec(unit: 'piece', precision: 0),
          ),
          holdings: const <CatalogHolding>[
            CatalogHolding(branchId: 'branch-north', quantityScaled: 1),
          ],
        ),
      ]);
    }

    await tester.pumpWidget(
      _app(Future<EmulatorSessionGateway>.value(gateway), catalogLoader: load),
    );
    await tester.pumpAndSettle();
    expect(find.text('Live product'), findsOneWidget);
    expect(catalogCalls, 1);

    await tester.tap(find.widgetWithText(OutlinedButton, 'Log out'));
    await tester.pump();
    gateway.sessions.add(_seller);
    await tester.pump();

    expect(gateway.logoutCalls, 1);
    expect(find.text('Live product'), findsNothing);
    expect(find.text('Local emulator sign in'), findsOneWidget);
    expect(catalogCalls, 1);
    signOut.complete();
    await tester.pumpAndSettle();
  });

  testWidgets(
    'remote null invalidates delayed login and a new login can succeed',
    (WidgetTester tester) async {
      final Completer<EmulatorSession> staleLogin =
          Completer<EmulatorSession>();
      final _FakeGateway gateway = _FakeGateway(loginCompleter: staleLogin);
      var catalogCalls = 0;
      Future<CatalogSnapshot> load(EmulatorSession session) async {
        catalogCalls += 1;
        return CatalogSnapshot(const <CatalogItem>[]);
      }

      await tester.pumpWidget(
        _app(Future<EmulatorSessionGateway>.value(gateway), catalogLoader: load),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey<String>('login-email')),
        'seller.north@demo-lda-inventory.invalid',
      );
      await tester.enterText(
        find.byKey(const ValueKey<String>('login-password')),
        'Demo-Only-Seller-2026!',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
      await tester.pump();

      gateway.sessions.add(null);
      await tester.pump();
      staleLogin.complete(_seller);
      await tester.pumpAndSettle();

      expect(find.text('Local emulator sign in'), findsOneWidget);
      expect(find.text('Authenticated locally'), findsNothing);
      expect(catalogCalls, 0);
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Sign in'),
            )
            .onPressed,
        isNotNull,
      );

      final Completer<EmulatorSession> newLogin =
          Completer<EmulatorSession>();
      gateway.loginCompleter = newLogin;
      await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
      await tester.pump();
      newLogin.complete(_seller);
      await tester.pumpAndSettle();

      expect(find.text('Authenticated locally'), findsOneWidget);
      expect(catalogCalls, 1);
    },
  );

  testWidgets('stale login failure cannot cancel a newer attempt', (
    WidgetTester tester,
  ) async {
    final Completer<EmulatorSession> staleLogin =
        Completer<EmulatorSession>();
    final _FakeGateway gateway = _FakeGateway(loginCompleter: staleLogin);
    var catalogCalls = 0;

    await tester.pumpWidget(
      _app(
        Future<EmulatorSessionGateway>.value(gateway),
        catalogLoader: (EmulatorSession session) async {
          catalogCalls += 1;
          return CatalogSnapshot(const <CatalogItem>[]);
        },
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('login-email')),
      'seller.north@demo-lda-inventory.invalid',
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('login-password')),
      'Demo-Only-Seller-2026!',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pump();

    gateway.sessions.add(null);
    await tester.pump();
    final Completer<EmulatorSession> newLogin =
        Completer<EmulatorSession>();
    gateway.loginCompleter = newLogin;
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pump();

    staleLogin.completeError(StateError('stale login failure detail'));
    await tester.pump();
    expect(find.textContaining('stale login failure detail'), findsNothing);
    expect(find.text('Unable to sign in to the local emulator.'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    newLogin.complete(_seller);
    await tester.pumpAndSettle();
    expect(find.text('Authenticated locally'), findsOneWidget);
    expect(catalogCalls, 1);
  });

  testWidgets('normal login notification does not duplicate catalog loading', (
    WidgetTester tester,
  ) async {
    final Completer<EmulatorSession> login = Completer<EmulatorSession>();
    final _FakeGateway gateway = _FakeGateway(loginCompleter: login);
    var catalogCalls = 0;
    Future<CatalogSnapshot> load(EmulatorSession session) async {
      catalogCalls += 1;
      return CatalogSnapshot(const <CatalogItem>[]);
    }

    await tester.pumpWidget(
      _app(Future<EmulatorSessionGateway>.value(gateway), catalogLoader: load),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('login-email')),
      'seller.north@demo-lda-inventory.invalid',
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('login-password')),
      'Demo-Only-Seller-2026!',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pump();

    gateway.sessions.add(_seller);
    await tester.pumpAndSettle();
    expect(find.text('Authenticated locally'), findsOneWidget);
    expect(catalogCalls, 1);

    login.complete(_seller);
    await tester.pumpAndSettle();
    expect(find.text('Authenticated locally'), findsOneWidget);
    expect(catalogCalls, 1);
  });

  testWidgets('pending login is superseded by a newer lifecycle error', (
    WidgetTester tester,
  ) async {
    final Completer<EmulatorSession> login = Completer<EmulatorSession>();
    final _FakeGateway gateway = _FakeGateway(loginCompleter: login);
    var catalogCalls = 0;

    await tester.pumpWidget(
      _app(
        Future<EmulatorSessionGateway>.value(gateway),
        catalogLoader: (EmulatorSession session) async {
          catalogCalls += 1;
          return CatalogSnapshot(const <CatalogItem>[]);
        },
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('login-email')),
      'seller.north@demo-lda-inventory.invalid',
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('login-password')),
      'Demo-Only-Seller-2026!',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pump();

    gateway.sessions.addError(const UntrustedSessionException());
    await tester.pumpAndSettle();
    expect(find.text('Session rejected'), findsOneWidget);

    login.complete(_seller);
    await tester.pumpAndSettle();
    expect(find.text('Session rejected'), findsOneWidget);
    expect(find.text('Authenticated locally'), findsNothing);
    expect(catalogCalls, 0);
  });

  testWidgets('stale pending login cannot override a newer logout', (
    WidgetTester tester,
  ) async {
    final Completer<EmulatorSession> login = Completer<EmulatorSession>();
    final _FakeGateway gateway = _FakeGateway(loginCompleter: login);
    var catalogCalls = 0;
    Future<CatalogSnapshot> load(EmulatorSession session) async {
      catalogCalls += 1;
      return CatalogSnapshot(const <CatalogItem>[]);
    }

    await tester.pumpWidget(
      _app(Future<EmulatorSessionGateway>.value(gateway), catalogLoader: load),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('login-email')),
      'seller.north@demo-lda-inventory.invalid',
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('login-password')),
      'Demo-Only-Seller-2026!',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pump();

    gateway.sessions.add(_seller);
    await tester.pumpAndSettle();
    expect(find.text('Authenticated locally'), findsOneWidget);
    expect(catalogCalls, 1);

    await tester.tap(find.widgetWithText(OutlinedButton, 'Log out'));
    await tester.pumpAndSettle();
    login.complete(_seller);
    await tester.pumpAndSettle();

    expect(find.text('Local emulator sign in'), findsOneWidget);
    expect(find.text('Authenticated locally'), findsNothing);
    expect(catalogCalls, 1);
  });

  testWidgets('failed logout stays signed out until explicit login succeeds', (
    WidgetTester tester,
  ) async {
    final Completer<void> signOut = Completer<void>();
    final _FakeGateway gateway = _FakeGateway(
      restored: _seller,
      loginResult: _seller,
      logoutCompleter: signOut,
    );
    var catalogCalls = 0;
    Future<CatalogSnapshot> load(EmulatorSession session) async {
      catalogCalls += 1;
      if (session.role == InventoryRole.administrator) {
        return CatalogSnapshot(const <CatalogItem>[]);
      }
      return CatalogSnapshot(<CatalogItem>[
        CatalogItem(
          product: const CatalogProduct(
            internalCode: 'PRD-LIVE-001',
            name: 'Live product',
            quantitySpec: QuantitySpec(unit: 'piece', precision: 0),
          ),
          holdings: const <CatalogHolding>[
            CatalogHolding(branchId: 'branch-north', quantityScaled: 1),
          ],
        ),
      ]);
    }

    await tester.pumpWidget(
      _app(Future<EmulatorSessionGateway>.value(gateway), catalogLoader: load),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(OutlinedButton, 'Log out'));
    await tester.pump();

    signOut.completeError(StateError('sanitized logout failure'));
    gateway.sessions.add(_seller);
    await tester.pumpAndSettle();

    expect(find.text('Local emulator sign in'), findsOneWidget);
    expect(find.text('Live product'), findsNothing);
    expect(find.textContaining('sanitized logout failure'), findsNothing);
    expect(catalogCalls, 1);

    expect(
      tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Sign in')).onPressed,
      isNotNull,
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('login-email')),
      'seller.north@demo-lda-inventory.invalid',
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('login-password')),
      'Demo-Only-Seller-2026!',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pumpAndSettle();

    expect(find.text('Live product'), findsOneWidget);
    expect(catalogCalls, 2);

    gateway.sessions.add(
      const EmulatorSession(
        userId: 'demo-local-administrator',
        email: 'administrator@demo-lda-inventory.invalid',
        role: InventoryRole.administrator,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Role: administrator'), findsOneWidget);
    expect(catalogCalls, 3);
  });

  testWidgets('bootstrap failure is fail-closed and retryable', (
    WidgetTester tester,
  ) async {
    final Completer<EmulatorSessionGateway> first =
        Completer<EmulatorSessionGateway>();
    final _FakeGateway retryGateway = _FakeGateway();
    await tester.pumpWidget(
      MaterialApp(
        home: EmulatorLoginShell(
          sessionGateway: first.future,
          retryLoader: () async => retryGateway,
          catalogLoader: _emptyCatalog,
        ),
      ),
    );
    first.completeError(StateError('host unavailable'));
    await tester.pumpAndSettle();

    expect(find.text('Local Auth emulator unavailable'), findsOneWidget);
    expect(find.textContaining('host unavailable'), findsNothing);
    expect(find.text('Catalog data not loaded.'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Try again'));
    await tester.pumpAndSettle();
    expect(find.text('Local emulator sign in'), findsOneWidget);
  });
}
