import 'package:firebase_auth/firebase_auth.dart';

import 'emulator_session.dart';

/// The shortest password the server policy accepts.
const int minimumPasswordLength = 10;

/// A gateway for the two password operations an account can do itself.
abstract interface class AccountPasswordGateway {
  /// Sends the reset email. Unknown addresses answer like known ones.
  Future<void> sendResetEmail(String email);

  /// Reauthenticates with [currentPassword] and stores [newPassword].
  Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
  });
}

/// The first problem with a password change, or null when it may be sent.
///
/// Checks run in the order the person fills the form: the current password,
/// the new length, the repeat and finally that the new one differs.
String? validatePasswordChange({
  required String currentPassword,
  required String newPassword,
  required String repeatedPassword,
}) {
  if (currentPassword.isEmpty) return 'Escribe tu contraseña actual.';
  if (newPassword.length < minimumPasswordLength) {
    return 'La contraseña debe tener al menos $minimumPasswordLength caracteres.';
  }
  if (newPassword != repeatedPassword) {
    return 'Las dos contraseñas no coinciden.';
  }
  if (newPassword == currentPassword) {
    return 'La contraseña nueva debe ser distinta de la actual.';
  }
  return null;
}

/// Maps a Firebase Auth error code raised while changing a password.
LoginFailure classifyPasswordChangeFailure(String code) => switch (code) {
  'wrong-password' ||
  'invalid-credential' => const WrongCurrentPasswordFailure(),
  'weak-password' ||
  'password-does-not-meet-requirements' => const WeakPasswordFailure(),
  'too-many-requests' => const TooManyAttemptsFailure(),
  'requires-recent-login' => const ReauthenticationRequiredFailure(),
  _ => const LoginConnectionFailure(),
};

/// The Spanish explanation for a password-change failure.
String passwordChangeFailureText(LoginFailure failure) =>
    loginFailureText(failure);

/// Firebase-backed [AccountPasswordGateway] for [FirebaseAuth].
class FirebaseAccountPasswordGateway implements AccountPasswordGateway {
  FirebaseAccountPasswordGateway(this._auth);

  final FirebaseAuth _auth;

  @override
  Future<void> sendResetEmail(String email) async {
    try {
      await _auth.sendPasswordResetEmail(email: email.trim());
    } on FirebaseAuthException catch (error) {
      switch (error.code) {
        case 'user-not-found':
        case 'invalid-email':
          // The screen answers the same way for every address, and the
          // project enables improved email privacy, so nothing leaks.
          return;
        case 'too-many-requests':
          throw const TooManyAttemptsFailure();
        default:
          throw const LoginConnectionFailure();
      }
    }
  }

  @override
  Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    final User? user = _auth.currentUser;
    final String? email = user?.email;
    if (user == null || email == null) {
      throw const ReauthenticationRequiredFailure();
    }
    try {
      await user.reauthenticateWithCredential(
        EmailAuthProvider.credential(email: email, password: currentPassword),
      );
      await user.updatePassword(newPassword);
    } on FirebaseAuthException catch (error) {
      throw classifyPasswordChangeFailure(error.code);
    }
  }
}
