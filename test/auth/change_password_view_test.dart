import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/auth/account_password.dart';
import 'package:lda_inventory/auth/change_password_view.dart';
import 'package:lda_inventory/auth/emulator_session.dart';

class _RecordingGateway implements AccountPasswordGateway {
  _RecordingGateway({this.failure});

  final LoginFailure? failure;
  final List<(String, String)> changes = <(String, String)>[];

  @override
  Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    if (failure != null) throw failure!;
    changes.add((currentPassword, newPassword));
  }

  @override
  Future<void> sendResetEmail(String email) async {}
}

Widget _app(AccountPasswordGateway gateway) =>
    MaterialApp(home: ChangePasswordView(gateway: gateway));

Future<void> _fill(
  WidgetTester tester, {
  String current = 'actual-larga',
  String next = 'unaClaveLarga123',
  String repeat = 'unaClaveLarga123',
}) async {
  await tester.enterText(
    find.widgetWithText(TextField, 'Contraseña actual'),
    current,
  );
  await tester.enterText(
    find.widgetWithText(TextField, 'Contraseña nueva'),
    next,
  );
  await tester.enterText(
    find.widgetWithText(TextField, 'Repite la contraseña nueva'),
    repeat,
  );
}

void main() {
  testWidgets('states the minimum length and the three fields', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_app(_RecordingGateway()));

    expect(
      find.text('Elige una contraseña de al menos 10 caracteres.'),
      findsOneWidget,
    );
    expect(find.widgetWithText(TextField, 'Contraseña actual'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Contraseña nueva'), findsOneWidget);
    expect(
      find.widgetWithText(TextField, 'Repite la contraseña nueva'),
      findsOneWidget,
    );
  });

  testWidgets('refuses a short password without calling the gateway', (
    WidgetTester tester,
  ) async {
    final _RecordingGateway gateway = _RecordingGateway();
    await tester.pumpWidget(_app(gateway));

    await _fill(tester, next: 'corta', repeat: 'corta');
    await tester.tap(find.text('Guardar contraseña'));
    await tester.pumpAndSettle();

    expect(
      find.text('La contraseña debe tener al menos 10 caracteres.'),
      findsOneWidget,
    );
    expect(gateway.changes, isEmpty);
  });

  testWidgets('sends the change and confirms it', (WidgetTester tester) async {
    final _RecordingGateway gateway = _RecordingGateway();
    await tester.pumpWidget(_app(gateway));

    await _fill(tester);
    await tester.tap(find.text('Guardar contraseña'));
    await tester.pumpAndSettle();

    expect(gateway.changes, <(String, String)>[
      ('actual-larga', 'unaClaveLarga123'),
    ]);
    expect(find.text('Contraseña actualizada.'), findsOneWidget);
  });

  testWidgets('explains a wrong current password', (WidgetTester tester) async {
    final _RecordingGateway gateway = _RecordingGateway(
      failure: const WrongCurrentPasswordFailure(),
    );
    await tester.pumpWidget(_app(gateway));

    await _fill(tester);
    await tester.tap(find.text('Guardar contraseña'));
    await tester.pumpAndSettle();

    expect(find.text('La contraseña actual no es correcta.'), findsOneWidget);
    expect(find.text('Contraseña actualizada.'), findsNothing);
  });

  testWidgets('explains a server policy refusal', (WidgetTester tester) async {
    final _RecordingGateway gateway = _RecordingGateway(
      failure: const WeakPasswordFailure(),
    );
    await tester.pumpWidget(_app(gateway));

    await _fill(tester);
    await tester.tap(find.text('Guardar contraseña'));
    await tester.pumpAndSettle();

    expect(
      find.text(
        'La contraseña no cumple la política: usa al menos 10 caracteres.',
      ),
      findsOneWidget,
    );
  });
}
