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

  testWidgets(
    'refuses two different new passwords without calling the gateway',
    (WidgetTester tester) async {
      final _RecordingGateway gateway = _RecordingGateway();
      await tester.pumpWidget(_app(gateway));

      await _fill(tester, repeat: 'otraClaveLarga1');
      await tester.tap(find.text('Guardar contraseña'));
      await tester.pumpAndSettle();

      expect(find.text('Las dos contraseñas no coinciden.'), findsOneWidget);
      expect(find.text('Contraseña actualizada.'), findsNothing);
      expect(gateway.changes, isEmpty);
    },
  );

  testWidgets('on a wide screen the suggestions sit beside the form', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_app(_RecordingGateway()));
    await tester.pumpAndSettle();

    final Finder card = find.byKey(
      const ValueKey<String>('change-password-context'),
    );
    expect(card, findsOneWidget);
    for (final String note in <String>[
      'Sugerencias',
      'Usa al menos 10 caracteres.',
      'Una frase de varias palabras es fácil de recordar y difícil de adivinar.',
      'No uses la misma contraseña que en otros servicios.',
      'Si la olvidas, usa «¿Olvidaste tu contraseña?» al iniciar sesión.',
    ]) {
      expect(
        find.descendant(of: card, matching: find.text(note)),
        findsOneWidget,
        reason: note,
      );
    }
    final Finder form = find.widgetWithText(TextField, 'Contraseña actual');
    expect(
      tester.getTopLeft(card).dx,
      greaterThan(tester.getTopRight(form).dx),
    );
  });

  testWidgets('on a compact screen only the form is shown', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_app(_RecordingGateway()));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('change-password-context')),
      findsNothing,
    );
    expect(
      find.text('Elige una contraseña de al menos 10 caracteres.'),
      findsOneWidget,
    );
    expect(find.text('Guardar contraseña'), findsOneWidget);
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
