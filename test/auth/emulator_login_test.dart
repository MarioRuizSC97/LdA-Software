import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/auth/emulator_login.dart';
import 'package:lda_inventory/auth/emulator_session.dart';

class _FakeGateway implements EmulatorSessionGateway {
  _FakeGateway({
    this.restored,
    this.restoreError,
    this.loginResult,
    this.loginError,
  });

  final EmulatorSession? restored;
  Object? restoreError;
  final EmulatorSession? loginResult;
  final Object? loginError;
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
    return loginResult!;
  }

  @override
  Future<void> logout() async {
    logoutCalls += 1;
  }
}

const EmulatorSession _seller = EmulatorSession(
  userId: 'demo-local-seller-north',
  email: 'seller.north@demo-lda-inventory.invalid',
  role: InventoryRole.seller,
  branchId: 'branch-north',
);

Widget _app(Future<EmulatorSessionGateway> gateway) =>
    MaterialApp(home: EmulatorLoginShell(sessionGateway: gateway));

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

  testWidgets('logs in and shows validated session without catalog claims', (
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
    expect(find.text('Catalog data not loaded.'), findsOneWidget);
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
        home: EmulatorLoginShell(sessionGateway: loader(), retryLoader: loader),
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
