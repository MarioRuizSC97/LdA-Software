import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/auth/account_password.dart';
import 'package:lda_inventory/auth/emulator_session.dart';

void main() {
  group('validatePasswordChange', () {
    String? check({
      String current = 'actual-larga',
      String next = 'unaClaveLarga123',
      String repeat = 'unaClaveLarga123',
    }) => validatePasswordChange(
      currentPassword: current,
      newPassword: next,
      repeatedPassword: repeat,
    );

    test('accepts a complete, long and matching change', () {
      expect(check(), isNull);
    });

    test('asks for the current password', () {
      expect(check(current: ''), 'Escribe tu contraseña actual.');
    });

    test('refuses a new password under ten characters', () {
      expect(
        check(next: 'nueve1234', repeat: 'nueve1234'),
        'La contraseña debe tener al menos 10 caracteres.',
      );
    });

    test('refuses a repeated password that does not match', () {
      expect(
        check(repeat: 'otraClaveLarga1'),
        'Las dos contraseñas no coinciden.',
      );
    });

    test('refuses reusing the current password', () {
      expect(
        check(current: 'unaClaveLarga123', next: 'unaClaveLarga123'),
        'La contraseña nueva debe ser distinta de la actual.',
      );
    });

    test('checks the length before the match, in that order', () {
      expect(
        check(next: 'corta', repeat: 'otra'),
        'La contraseña debe tener al menos 10 caracteres.',
      );
    });
  });

  group('classifyPasswordChangeFailure', () {
    test('recognises a wrong current password', () {
      for (final String code in <String>[
        'wrong-password',
        'invalid-credential',
      ]) {
        expect(
          classifyPasswordChangeFailure(code),
          isA<WrongCurrentPasswordFailure>(),
          reason: code,
        );
      }
    });

    test('recognises a password refused by the server policy', () {
      for (final String code in <String>[
        'weak-password',
        'password-does-not-meet-requirements',
      ]) {
        expect(
          classifyPasswordChangeFailure(code),
          isA<WeakPasswordFailure>(),
          reason: code,
        );
      }
    });

    test('recognises throttling and requires a new sign-in', () {
      expect(
        classifyPasswordChangeFailure('too-many-requests'),
        isA<TooManyAttemptsFailure>(),
      );
      expect(
        classifyPasswordChangeFailure('requires-recent-login'),
        isA<ReauthenticationRequiredFailure>(),
      );
    });

    test('everything else is a connection failure', () {
      expect(
        classifyPasswordChangeFailure('network-request-failed'),
        isA<LoginConnectionFailure>(),
      );
    });
  });

  group('passwordChangeFailureText', () {
    test('explains a wrong current password without blaming the session', () {
      expect(
        passwordChangeFailureText(const WrongCurrentPasswordFailure()),
        'La contraseña actual no es correcta.',
      );
    });

    test('explains that the session must be confirmed again', () {
      expect(
        passwordChangeFailureText(const ReauthenticationRequiredFailure()),
        'Por seguridad, vuelve a iniciar sesión y repite el cambio.',
      );
    });
  });
}
