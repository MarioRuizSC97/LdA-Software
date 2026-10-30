import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/app/backend_environment.dart';
import 'package:lda_inventory/auth/account_password.dart';
import 'package:lda_inventory/auth/emulator_login.dart';
import 'package:lda_inventory/auth/emulator_session.dart';

class _SignedOutGateway implements EmulatorSessionGateway {
  @override
  Future<EmulatorSession?> restoreSession() async => null;

  @override
  Stream<EmulatorSession?> sessionChanges() => const Stream.empty();

  @override
  Future<EmulatorSession> login({
    required String email,
    required String password,
  }) => throw UnimplementedError();

  @override
  Future<void> logout() async {}
}

class _PasswordGateway extends _SignedOutGateway
    implements AccountPasswordGateway {
  final List<String> resets = <String>[];

  @override
  Future<void> sendResetEmail(String email) async => resets.add(email);

  @override
  Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
  }) async {}
}

Widget _login(EmulatorSessionGateway gateway) => MaterialApp(
  home: EmulatorLoginShell(
    environment: BackendEnvironment.production,
    sessionGateway: Future<EmulatorSessionGateway>.value(gateway),
    catalogLoader: (EmulatorSession session) async =>
        throw StateError('stays signed out'),
  ),
);

void main() {
  testWidgets('without a password gateway the action is hidden', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_login(_SignedOutGateway()));
    await tester.pumpAndSettle();
    expect(find.text('¿Olvidaste tu contraseña?'), findsNothing);
  });

  testWidgets('with a password gateway the action is offered', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_login(_PasswordGateway()));
    await tester.pumpAndSettle();
    expect(find.text('¿Olvidaste tu contraseña?'), findsOneWidget);
  });

  testWidgets('sending the reset answers the same way and calls the gateway', (
    WidgetTester tester,
  ) async {
    final _PasswordGateway gateway = _PasswordGateway();
    await tester.pumpWidget(_login(gateway));
    await tester.pumpAndSettle();

    await tester.tap(find.text('¿Olvidaste tu contraseña?'));
    await tester.pumpAndSettle();
    expect(find.text('Restablecer contraseña'), findsOneWidget);

    await tester.enterText(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      ),
      'persona@example.invalid',
    );
    await tester.tap(find.text('Enviar enlace'));
    await tester.pumpAndSettle();

    expect(gateway.resets, <String>['persona@example.invalid']);
    expect(
      find.text(
        'Si el correo existe, enviamos un enlace para restablecer '
        'la contraseña.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('cancelling sends nothing', (WidgetTester tester) async {
    final _PasswordGateway gateway = _PasswordGateway();
    await tester.pumpWidget(_login(gateway));
    await tester.pumpAndSettle();

    await tester.tap(find.text('¿Olvidaste tu contraseña?'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancelar'));
    await tester.pumpAndSettle();

    expect(gateway.resets, isEmpty);
    expect(find.text('Restablecer contraseña'), findsNothing);
  });
}
