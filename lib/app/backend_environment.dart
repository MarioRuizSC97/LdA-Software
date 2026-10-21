/// Which Firebase backend the signed-in app talks to. It only changes the
/// connection copy the user reads; the session and gateways are identical.
enum BackendEnvironment {
  /// The local Firebase emulators (`LDA_LOCAL_EMULATORS=true`).
  localEmulator,

  /// The real Firebase project (`LDA_FIREBASE_PRODUCTION=true`).
  production;

  String get connectingLabel => switch (this) {
    localEmulator => 'Conectando con el emulador local de autenticación',
    production => 'Conectando con el servidor',
  };

  String get loginTitle => switch (this) {
    localEmulator => 'Inicio de sesión en el emulador local',
    production => 'Inicio de sesión',
  };

  /// A note under the login title, or null for none.
  String? get loginNote => switch (this) {
    localEmulator => 'Los datos del catálogo no están conectados.',
    production => null,
  };

  String get loginFailure => switch (this) {
    localEmulator => 'No se pudo iniciar sesión en el emulador local.',
    production => 'No se pudo iniciar sesión.',
  };

  /// Leads the app bar session status, or null for none. Production shows
  /// only role and branch; local sessions stay visibly marked as local.
  String? get sessionStatusPrefix => switch (this) {
    localEmulator => 'Emulador local',
    production => null,
  };
}
