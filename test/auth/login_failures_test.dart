import 'package:flutter_test/flutter_test.dart';
import 'package:lda_inventory/auth/emulator_session.dart';

void main() {
  group('classifyLoginFailure', () {
    test('recognises the server password policy refusal', () {
      expect(
        classifyLoginFailure('password-login-requires-password-change'),
        isA<PasswordChangeRequiredFailure>(),
      );
    });

    test('recognises a throttled account', () {
      expect(
        classifyLoginFailure('too-many-requests'),
        isA<TooManyAttemptsFailure>(),
      );
    });

    test('recognises a rejected new password', () {
      expect(classifyLoginFailure('weak-password'), isA<WeakPasswordFailure>());
    });

    test('anything else stays a connection failure', () {
      for (final String code in <String>[
        'network-request-failed',
        'internal-error',
        'unknown',
        '',
      ]) {
        expect(classifyLoginFailure(code), isA<LoginConnectionFailure>());
      }
    });
  });

  group('loginFailureText', () {
    test('explains that the password must be replaced, not retyped', () {
      expect(
        loginFailureText(const PasswordChangeRequiredFailure()),
        'Tu contraseña debe actualizarse. Usa «¿Olvidaste tu contraseña?» '
        'para crear una nueva.',
      );
    });

    test('explains a temporary block and what to do', () {
      expect(
        loginFailureText(const TooManyAttemptsFailure()),
        'Demasiados intentos. Espera unos minutos y vuelve a intentar.',
      );
    });

    test('explains that the new password is too short', () {
      expect(
        loginFailureText(const WeakPasswordFailure()),
        'La contraseña no cumple la política: usa al menos 10 caracteres.',
      );
    });

    test('keeps the generic message for connection problems', () {
      expect(
        loginFailureText(const LoginConnectionFailure()),
        'No se pudo iniciar sesión. Revisa los datos y vuelve a intentar.',
      );
    });
  });
}
